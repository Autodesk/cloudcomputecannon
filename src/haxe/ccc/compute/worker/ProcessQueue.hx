package ccc.compute.worker;

import haxe.extern.EitherType;

import ccc.storage.ServiceStorage;

import js.npm.bull.Bull;

import promhx.deferred.DeferredPromise;

/**
 * The main class for pulling jobs off the queue and
 * executing them.
 *
 * Currently this only supports local job execution
 * meaning this process is expecting to be in the
 * same process as the worker.
 */

typedef JobTypes=EitherType<DockerBatchComputeJob,BatchProcessRequestTurboV2>;
typedef JobResults=EitherType<JobResult,JobResultsTurboV2>;

typedef RedisConnection = {
	var host :String;
	@:optional var port :Int;
	@:optional var opts :Dynamic;
}

typedef QueueArguments = {
	var redis: RedisConnection;
	var log :AbstractLogger;
}

typedef ProcessArguments = { >QueueArguments,
	@:optional var cpus :Int;
	var remoteStorage :ServiceStorage;
}

typedef QueueJob<T:(JobTypes)> = {//BatchProcessRequestTurboV2
	var jobId :JobId;
	var attempt :Int;
	var type :QueueJobDefinitionType;
	@:optional var item :T;
	@:optional var parameters :JobParams;
}

enum ProcessFinishReason {
	Cancelled;
	Success(result :JobResult);
	Stalled;
	Error(err :Dynamic);
	Timeout;
	DockerContainerKilled;
	/* This should not happen, but it does */
	MissingJobDefinition;
	AlreadyFinished;
	MaximumAttemptsExceeded;
}

class ProcessQueue
{
	@inject('REDIS_HOST') public var redisHost :String;
	@inject('REDIS_PORT') public var redisPort :Int;
	@inject public var _redis :RedisClient;
	@inject public var _docker :Docker;
	@inject public var _remoteStorage :ServiceStorage;
	@inject public var _injector :Injector;
	@inject public var _workerId :MachineId;
	@inject public var log :AbstractLogger;
	@inject('StatusStream') public var statusStream :Stream<ccc.JobStatsData>;
	@inject('WorkerStream') public var _workerStream :Stream<ccc.WorkerState>;
	@inject public var internalState :WorkerStateInternal;

	public var queueProcess (default, null) :js.npm.bull.Bull.Queue<QueueJob<JobTypes>,JobResults>;
	var queueAdd (default, null) :js.npm.bull.Bull.Queue<QueueJob<JobTypes>,JobResults>;

	public var cpus (get, null):Int;
	var _cpus :Int = 1;
	function get_cpus() :Int {return _cpus;}

	public var jobs (get, null):Int;
	var _jobs :Int = 0;
	function get_jobs() :Int {return _jobs;}

	public var ready (get, null) :Promise<Bool>;
	function get_ready() :Promise<Bool> {return _ready.boundPromise;}
	var _ready :DeferredPromise<Bool> = new DeferredPromise();

	public var _localJobProcess :Map<JobId,Array<JobProcessObject>> = new Map();
	var _isPaused :Bool = false;

	public function new() {}

	public function isQueueEmpty() :Bool
	{
		return !_localJobProcess.keys().hasNext();
	}

	/**
	 * This adds the job to the queue, it does not add the
	 * job to this instance.
	 * @param job :QueueJobDefinition [description]
	 */
	public function add(job :QueueJobDefinition<JobTypes>) :Promise<Bool>
	{
		return switch(job.type) {
			case compute:
				Promise.promise(true)
					.pipe(function(_) {
						log.info(LogFieldUtil.addJobEvent({jobId:job.id, type:job.type, message:'via ProcessQueue'}, JobEventType.ENQUEUED));

						return Promise.whenAll([
							Jobs.setJob(job.id, job.item),
							Jobs.setJobParameters(job.id, job.parameters),
							JobStatsTools.jobEnqueued(job.id, job.item)
								.thenTrue()
						]);
					})
					.then(function(_) {
						queueAdd.add({jobId:job.id, attempt: job.attempt, type:job.type}, {jobId:job.id, priority:(job.priority ? 1 : 1000), removeOnComplete:true, removeOnFail:true});
						return true;
					});
			case turbo:
				log.info(LogFieldUtil.addJobEvent({jobId:job.id, type:job.type, message:'via ProcessQueue'}, JobEventType.ENQUEUED));
				var maxTime = 300000;//5 minutes max
				queueAdd.add({jobId:job.id, attempt: 1, type:job.type, item: job.item, parameters:job.parameters}, {jobId:job.id, priority:1, removeOnComplete:true, removeOnFail:true, timeout:maxTime});
				Promise.promise(true);
		}
	}

	public function cancel(jobId :JobId) :Promise<Bool>
	{
		var jobProcesses = _localJobProcess.get(jobId);
		if (jobProcesses != null) {
			jobProcesses.iter(function(j) if (j != null) j.cancel());
		}
		return Promise.promise(true);
	}

	public function stopQueue() :Promise<Bool>
	{
		queueProcess.close();
		if (_jobs == 0) {
			return Promise.promise(true);
		} else {
			var promise = new DeferredPromise();
			queueProcess.on(QueueEvent.Completed, function(job, result) {
				if (_jobs == 0 && !promise.isResolved()) {
					promise.resolve(true);
				} else {
					log.warn('stopQueue but _jobs=$_jobs and just got event=${QueueEvent.Completed}. When will this end?');
					Node.setTimeout(function() {
						if (!promise.isResolved()) {
							if (_jobs == 0) {
								promise.resolve(true);
							}
						}
					}, 5000);
				}
			});
			return promise.boundPromise;
		}
	}

	function jobProcesser(queueJob :Job<QueueJob<JobTypes>>, done :Done2<JobResults>) :Void
	{
		switch(queueJob.data.type) {
			case compute:
				//Cast it into the fully typed version for the compiler
				var queuejob :Job<QueueJob<DockerBatchComputeJob>> = queueJob;
				JobStatsTools.isJob(queuejob.data.jobId)
					.pipe(function(isJob) {

						if (!isJob) {
							done(null, null);
							traceYellow('No job for ${queuejob.data.jobId} it must have been cancelled+removed. Do not log this long term');
							log.debug(LogFieldUtil.addJobEvent({jobId:queuejob.data.jobId, type:queueJob.data.type, reason:Type.enumConstructor(ProcessFinishReason.MissingJobDefinition)}, JobEventType.FINISHED));
							return Promise.promise(true);
						}

						var jobProcessObject = new JobProcessObject(queuejob, done);
						_injector.injectInto(jobProcessObject);

						Assert.notNull(jobProcessObject.jobId);
						var jobId = queuejob.data.jobId;
						var attempt = queuejob.data.attempt;
						if (!_localJobProcess.exists(jobId)) {
							_localJobProcess.set(jobId, []);
						}
						Assert.that(_localJobProcess.get(jobId)[attempt - 1] == null);
						_localJobProcess.get(jobId)[attempt - 1] = jobProcessObject;

						var internalState :WorkerStateInternal = _injector.getValue('ccc.WorkerStateInternal');
						var workingJobs : Array<JobId> = internalState.jobs;
						if (!workingJobs.has(jobId)) {
							workingJobs.push(jobId);
						}

						return jobProcessObject.finished
							.pipe(function(shouldRetry) {
								if (shouldRetry) {
									log.info(LogFieldUtil.addJobEvent({jobId:jobId, type:queueJob.data.type}, JobEventType.RESTARTED));
									log.info(LogFieldUtil.addJobEvent({jobId:jobId, type:queueJob.data.type, message:'retrying'}, JobEventType.ENQUEUED));
									return JobStatsTools.jobEnqueued(jobId, null)
										.then(function(newAttempt) {
											log.warn({message: 'Retrying!', previous_attempt:attempt, attempt:newAttempt});
											queueAdd.add({jobId:jobId, attempt: newAttempt, type: queueJob.data.type}, {removeOnComplete:true});
											return true;
										});
								} else {
									return Promise.promise(true);
								}
							})
							.errorPipe(function(err) {
								log.error({jobId: jobProcessObject.jobId, attempt:attempt, error:err, log:'jobProcesser jobProcessObject.finished'});
								return Promise.promise(false);
							})
							.then(function(_) {
								jobProcessObject.dispose();
								workingJobs.remove(jobId);
								_localJobProcess.get(jobProcessObject.jobId)[attempt - 1] = null;
								if (_localJobProcess.get(jobProcessObject.jobId).count(function(e) return e != null) == 0) {
									_localJobProcess.remove(jobProcessObject.jobId);
								}
								return true;
							});
					});
			case turbo:
				var queuejob :Job<QueueJob<BatchProcessRequestTurboV2>> = queueJob;
				var redis :RedisClient = _injector.getValue(RedisClient);
				var docker :Docker = _injector.getValue(Docker);
				var thisMachineId = _injector.getValue(MachineId);
				Assert.notNull(thisMachineId);
				log.info(LogFieldUtil.addJobEvent({jobId:queuejob.data.item.id, worker:_workerId, type:queueJob.data.type}, JobEventType.DEQUEUED));
				BatchComputeDockerTurbo.executeTurboJobV2(redis, queuejob.data.item, docker, thisMachineId, log)
					.pipe(function(result) {
						traceYellow('calling done in bull queue');
						done(null, result);
						log.info(LogFieldUtil.addJobEvent({exitCode:result.exitCode, error:result.error, jobId:queuejob.data.item.id, worker:_workerId, type:queueJob.data.type}, JobEventType.FINISHED));
						return Promise.promise(true);
					})
					.catchError(function(err) {
						log.error(LogFieldUtil.addJobEvent({error:err, message: 'Failed turbo job', queuejob:queuejob, jobId:queuejob.data.item.id, worker:_workerId, type:queueJob.data.type}, JobEventType.ERROR));
						done(err, js.Lib.undefined);
					});
		}
	}

	@post
	public function postInject()
	{
		log = log.child({c:ProcessQueue});

		Assert.notNull(_workerId);

		statusStream.then(function(statusUpdate) {
			if (_localJobProcess.exists(statusUpdate.jobId)) {
				if (statusUpdate.statusFinished == JobFinishedStatus.TimeOut) {
					_localJobProcess.get(statusUpdate.jobId).iter(function(j) if (j != null) j.timeout());
				} else if (statusUpdate.statusFinished == JobFinishedStatus.Killed) {
					_localJobProcess.get(statusUpdate.jobId).iter(function(j) if (j != null) j.cancel());
				}
			}
		});

		_cpus = 1;

		DockerPromises.info(_docker)
			.then(function(dockerInfo) {
				_cpus = dockerInfo.NCPU;

				switch (ServerConfig.CLOUD_PROVIDER_TYPE) {
					case Local: _cpus = 1;
					default:
				}


				internalState.ncpus = _cpus;

				var args :ProcessArguments = {
					redis : {
						host: redisHost,
						port: redisPort
					},
					cpus : _cpus,
					remoteStorage: _remoteStorage,
					log: log
				};

				queueProcess = createProcessorQueue(args, jobProcesser);
				queueAdd = createAddingQueue(args);

				//TODO: we used to have two queues. Now that there is only
				//one, we don't need this array, but I'll leave it here
				//in case there are more queues in the future.
				var queues = [queueProcess];

				for (q in queues) {

					q.on(QueueEvent.Error, function(err) {
						log.error({e:QueueEvent.Error, error:Json.stringify(err)});
					});

					q.on(QueueEvent.Active, function(job, promise) {
						try {
							log.debug({e:QueueEvent.Active, jobId:job.data.id});
						} catch(err :Dynamic) {trace(err);}
					});

					q.on(QueueEvent.Stalled, function(job) {
						log.warn({e:QueueEvent.Stalled, jobId:job.data.id});
					});

					q.on(QueueEvent.Progress, function(job, progress) {
						log.debug({e:QueueEvent.Progress, jobId:job.data.id, progress:progress});
					});

					q.on(QueueEvent.Completed, function(j :Job<Dynamic>, result) {
						//Turbo jobs get logged elsewhere
						var job :Job<QueueJob<Dynamic>> = cast j;
						log.debug({e:QueueEvent.Completed, jobId: job.data.jobId});
						if (job.data.type == QueueJobDefinitionType.compute) {
							log.debug({e:QueueEvent.Completed, jobId: job.data.jobId});
						}
					});

					q.on(QueueEvent.Failed, function(job, error :js.Error) {
						//Turbo jobs get logged elsewhere
						log.warn({e:QueueEvent.Failed, jobId:job.data.id, error:error});
						if (job.data.type == QueueJobDefinitionType.compute) {
							log.warn({e:QueueEvent.Failed, jobId:job.data.id, error:error});
						}
						if (error.message != null && error.message.indexOf('job stalled more than allowable limit') > -1) {
							job.retry();
						}
					});

					q.on(QueueEvent.Paused, function() {
						log.warn({e:QueueEvent.Paused});
					});

					q.on(QueueEvent.Resumed, function(job) {
						log.debug({e:QueueEvent.Resumed, jobId:job.data.id});
					});

					q.on(QueueEvent.Cleaned, function(jobs) {
						log.debug({e:QueueEvent.Cleaned, jobIds:jobs.map(function(j) return j.data.id).array()});
						return null;
					});
				}

				_workerStream.then(function(workerState :WorkerState) {
					for (q in queues) {
						if (_isPaused && workerState.status == WorkerStatus.OK) {
							q.resume(true).then(function(_) {
								log.warn({paused:false, status:workerState.status, statusHealth:workerState.statusHealth });
								_isPaused = false;
							});
						} else if (!_isPaused && workerState.status != WorkerStatus.OK) {
							q.pause(true).then(function(_) {
								log.warn({paused:true, status:workerState.status, statusHealth:workerState.statusHealth });
								_isPaused = true;
							});
						}
					}
				});

				_ready.resolve(true);
			});

		var messageQueue = new Queue(BullQueueNames.SingleMessageQueue, {redis:{port:redisPort, host:redisHost}});
		function messageQueueHandler(job, done) {
			var action :BullQueueSingleMessageQueueAction = job.data;
			var handled = false;
			switch(action.type) {
				case log:
					handled = true;
					var logBlob :BullQueueSingleMessageQueueActionLog = action.data;
					switch(logBlob.level) {
						case 'debug': log.debug(logBlob.obj);
						case 'info': log.info(logBlob.obj);
						case 'warn': log.warn(logBlob.obj);
						case 'error': log.error(logBlob.obj);
						case 'critical': log.critical(logBlob.obj);
						default: log.warn({message: 'unhandled error blob from redis', action:action});
					}
			}
			if (!handled) {
				log.warn({message: 'unhandled redis queue message', action:action});
			}
		}
		messageQueue.process(1, messageQueueHandler);

		addBullDashboard();
	}

	function addBullDashboard()
	{
		var bullArena = new js.npm.bullarena.BullArena(
			{
				queues:[
					{
						name: BullQueueNames.JobQueue,
						port: redisPort,
						host: redisHost,
						hostId: redisHost
					},
					{
						name: BullQueueNames.SingleMessageQueue,
						port: redisPort,
						host: redisHost,
						hostId: redisHost
					}
				]
			},
			{
				disableListen: true
			}
		);

		var app :Application = injector.getValue(Application);
		app.use('/dashboard', cast bullArena);
	}

	static function createProcessorQueue(args :ProcessArguments, jobProcessor: Job<QueueJob<Dynamic>>->Done2<JobResult>->Void)
	{
		var redisHost :String = args.redis.host;
		var redisPort :Int = args.redis.port != null ? args.redis.port : DEFAULT_REDIS_PORT;
		var cpus :Int = args.cpus != null ? args.cpus : 1;
		var queueName :String = BullQueueNames.JobQueue;
		var queue = new Queue(queueName, {redis:{port:redisPort, host:redisHost}});
		function processor(job, done) {
			jobProcessor(job, done);
		}
		queue.process(cpus, processor);
		return queue;
	}

	static function createAddingQueue(args :ProcessArguments)
	{
		var redisHost :String = args.redis.host;
		var redisPort :Int = args.redis.port != null ? args.redis.port : DEFAULT_REDIS_PORT;
		var queueName :String = BullQueueNames.JobQueue;
		var queue = new Queue(queueName, {redis:{port:redisPort, host:redisHost}});
		return queue;
	}
}

class JobProcessObject
{
	/**
	 * If an error is thrown
	 */
	public var finished (default, null):Promise<Bool>;

	@inject public var _redis :RedisClient;
	@inject public var _remoteStorage :ServiceStorage;
	@inject public var log :AbstractLogger;
	@inject public var _workerId :MachineId;

	public var jobId (default, null) :JobId;
	public var attempt (default, null) :Int;
	var _cancelled :Bool = false;

	var _queueJob :Job<QueueJob<DockerBatchComputeJob>>;
	var _done :Done2<JobResult>;
	var _isFinished :Bool = false;

	var _deferred :DeferredPromise<Bool>;
	var _killedDeferred :DeferredPromise<Bool> = new DeferredPromise();

	public function new(queueJob :Job<QueueJob<DockerBatchComputeJob>>, done :Done2<JobResult>)
	{
		_queueJob = queueJob;
		_done = done;
		var jobData = queueJob.data;
		this.jobId = jobData.jobId;
		this.attempt = jobData.attempt;
		_deferred = new DeferredPromise();
		this.finished = _deferred.boundPromise;
	}

	/**
	 * This can be called when it becomes stalled.
	 * This ensures that no more actions will be taken.
	 * @return [description]
	 */
	public function dispose()
	{
		_isFinished = true;
	}

	@post
	public function postInject()
	{
		log = log.child({jobId:jobId, attempt:attempt, type:_queueJob.data.type});
		Assert.notNull(_workerId);
		jobProcesser();
	}

	/**
	 * Called externally, by the user or system
	 * @return [description]
	 */
	public function cancel()
	{
		_cancelled = true;
		finish(ProcessFinishReason.Cancelled);
	}

	public function timeout()
	{
		_cancelled = true;
		finish(ProcessFinishReason.Timeout);
	}

	public function finish(reason :ProcessFinishReason) :Void
	{
		if (_isFinished) {
			return;
		}
		_isFinished = true;
		log.debug({log:'removing from queue', reason:reason.getName()});
		Jobs.removeJobWorker(jobId, _workerId)
			.then(function(_) {

				var retry = function(err :Dynamic) {
					log.debug({message:'Setting status to Pending then resolving the bull job', err:err});
					JobStateTools.setStatus(jobId, JobStatus.Pending)
						.then(function(_) {
							_done(null, null);
							_deferred.resolve(true);
						})
						.catchError(function(err) {
							log.warn({error:err, message: 'Was setting status to pending'});
							_done(null, null);
							_deferred.resolve(true);
						});
				}

				switch(reason) {
					case Cancelled,MissingJobDefinition,AlreadyFinished,MaximumAttemptsExceeded:
						log.info(LogFieldUtil.addJobEvent({reason:Type.enumConstructor(reason)}, JobEventType.FINISHED));
						_cancelled = true;
						_done(null, null);
						_deferred.resolve(false);
						_killedDeferred.resolve(true);
					case Success(jobResult):
						log.info(LogFieldUtil.addJobEvent({reason:'Success'}, JobEventType.FINISHED));
						_done(null, jobResult);
						_deferred.resolve(false);
					case Stalled:
						log.warn({message:'Got stalled job, hopefully it is back on the queue'});
						_killedDeferred.resolve(true);
						_deferred.resolve(false);
					case Error(err):
						if (err.message != null && err.message == JobSubmissionError.Docker_Image_Unknown) {
							log.info(LogFieldUtil.addJobEvent({reason:'Error', error:err}, JobEventType.FINISHED));
							_done(null, null);
							_deferred.resolve(false);
						} else {
							if (Json.stringify(err).indexOf('No job') > -1) {
								log.info(LogFieldUtil.addJobEvent({reason:'Error', error:err}, JobEventType.FINISHED));
								_done('No job=$jobId', null);
								_deferred.resolve(false);
								_killedDeferred.resolve(true);
							} else {
								log.info(LogFieldUtil.addJobEvent({error:err}, JobEventType.ERROR));
								log.warn({error:err, log:'Got error, retrying job'});
								retry(err);
							}
						}
					case Timeout:
						log.info(LogFieldUtil.addJobEvent({reason:Type.enumConstructor(reason)}, JobEventType.FINISHED));
						log.warn({error:'Timeout'});
						_done(null, null);
						_deferred.resolve(false);
						_killedDeferred.resolve(true);
					case DockerContainerKilled:
						log.warn({error:'DockerContainerKilled', retrying: true});
						retry('DockerContainerKilled');
				}
			})
			.catchError(function(err) {
				log.warn({error:err, message: 'Finishing job process'});
			});
	}

	function jobProcesser() :Void
	{
		var queueJob = _queueJob;
		var done = _done;
		try {
			var error :Dynamic = null;

			if (!_isFinished && attempt > ServerConfig.JOB_MAX_ATTEMPTS) {
				log.debug({statusFinished:JobFinishedStatus.TooManyFailedAttempts, ProcessFinishReason:Type.enumConstructor(ProcessFinishReason.MaximumAttemptsExceeded)});
				JobStatsTools.isJob(jobId)
					.pipe(function(isJob) {
						if (!isJob) {
							if (!_isFinished) {
								finish(ProcessFinishReason.MissingJobDefinition);
							}
							return Promise.promise(true);
						} else {
							var batchJobResult :BatchJobResult = {exitCode:-1, error:JobFinishedStatus.TooManyFailedAttempts, copiedLogs:false, timeout:false};
							return Jobs.getJob(jobId)
								.pipe(function(job) {
									return writeJobResults(_redis, job, _remoteStorage, batchJobResult, JobFinishedStatus.TooManyFailedAttempts)
										.pipe(function(jobResultBlob) {
											return JobStateTools.setFinishedStatus(jobId, JobFinishedStatus.TooManyFailedAttempts)
												.then(function(_) {
													if (!_isFinished) {
														finish(ProcessFinishReason.MaximumAttemptsExceeded);
													}
													return true;
												});
										});
									});
							}
					}).catchError(function(err) {
						log.warn({error:err, message: 'Setting JobStateTools.setFinishedStatus($jobId, JobFinishedStatus.TooManyFailedAttempts)'});
					});
				return;
			}

			JobStatsTools.isJob(jobId)
				.pipe(function(isJob) {
					if (!isJob) {
						finish(ProcessFinishReason.MissingJobDefinition);
						return Promise.promise(true);
					}

					return JobStateTools.getStatus(jobId)
						.pipe(function(status) {
							if (status == JobStatus.Finished) {
								if (!_isFinished) {
									finish(ProcessFinishReason.AlreadyFinished);
								}
							}
							return Promise.promise(true);
						})
						.pipe(function(_) {
							if (!_isFinished) {
								log.info(LogFieldUtil.addJobEvent({attempt:attempt, worker:_workerId}, JobEventType.DEQUEUED));
								return JobStatsTools.jobDequeued(jobId, attempt, _workerId)
									.thenTrue();
							} else {
								return Promise.promise(true);
							}
						})
						.pipe(function(_) {
							if (!_isFinished) {
								return JobStateTools.setStatus(jobId, JobStatus.Working);
							} else {
								return Promise.promise(true);
							}
						})
						.pipe(function(_) {
							return Jobs.getJob(jobId);
						})
						.pipe(function(job) {
							if (_isFinished) {
								return Promise.promise(true);
							}
							if (job == null) {
								log.error({error:'MissingJobDefinition'});
								finish(ProcessFinishReason.MissingJobDefinition);
								return Promise.promise(true);
							}

							return BatchComputeDocker.executeJob(_redis, job, attempt, DOCKER_CONNECT_OPTS_LOCAL, _remoteStorage, _killedDeferred.boundPromise, log)
								.promise
								.pipe(function(batchJobResult :BatchJobResult) {
									if (_isFinished) {
										return Promise.promise(true);
									} else {
										//This means that the container was killed externally
										if (batchJobResult.exitCode == 137) {
											if (!_isFinished) {
												finish(ProcessFinishReason.DockerContainerKilled);
											}
											return Promise.promise(true);
										} else if (batchJobResult.timeout) {
											return writeJobResults(_redis, job, _remoteStorage, batchJobResult, JobFinishedStatus.TimeOut)
												.pipe(function(jobResultBlob) {
													return JobStateTools.setFinishedStatus(jobId, JobFinishedStatus.TimeOut)
														.then(function(_) {
															return jobResultBlob;
														});
												})
												.then(function(jobResultBlob) {
													if (!_isFinished) {
														finish(ProcessFinishReason.Timeout);
													}
													return true;
												});
										} else {
											return writeJobResults(_redis, job, _remoteStorage, batchJobResult, batchJobResult.error != null ? JobFinishedStatus.Failed : JobFinishedStatus.Success)
												.pipe(function(jobResultBlob) {
													return JobStateTools.setFinishedStatus(jobId, JobFinishedStatus.Success)
														.then(function(_) {
															return jobResultBlob;
														});
												})
												.then(function(jobResultBlob) {
													if (!_isFinished) {
														if (batchJobResult.error == null) {
															finish(ProcessFinishReason.Success(jobResultBlob.jobResult));
														} else {
															finish(ProcessFinishReason.Error(batchJobResult.error));
														}
													}
													return true;
												});
										}
									}
								})
								.errorPipe(function(err) {
									log.error({error:err});
									//Write job as a failure
									//This should actually never happen, or the failure
									//should be handled
									var batchJobResult :BatchJobResult = {exitCode:-1, error:err, copiedLogs:false, timeout:false};
									// log.error({exitCode:-1, error:err, JobStatus:null, JobFinishedStatus:null});
									if (_isFinished) {
										return Promise.promise(true);
									} else {
										finish(ProcessFinishReason.Error(err));
										return Promise.promise(true);
										// return writeJobResults(_redis, job, _remoteStorage, batchJobResult, JobFinishedStatus.Failed)
										// 	.pipe(function(jobResultBlob) {
										// 		return JobStateTools.setFinishedStatus(jobId, JobFinishedStatus.Failed, Json.stringify(err))
										// 			.then(function(_) {
										// 				return jobResultBlob;
										// 			});
										// 	})
										// 	.then(function(jobResultBlob) {
										// 		log.debug({message:"Finished writing job"});
										// 		if (!_isFinished) {
										// 			finish(ProcessFinishReason.Success(jobResultBlob.jobResult));
										// 		}
										// 		return true;
										// 	})
										// 	.errorPipe(function(err) {
										// 		if (!_isFinished) {
										// 			finish(ProcessFinishReason.Error("Failed to write job results"));
										// 		}
										// 		return Promise.promise(true);
										// 	});
									}
								});
						});
				})
				.errorPipe(function(err) {
					if (!_isFinished) {
						finish(ProcessFinishReason.Error({error:err, stack: try{err.stack;}catch(err:Dynamic){null;}}));
					}
					return Promise.promise(true);
				});
		} catch(e :Dynamic) {
			log.error({error:e, m:'FAILED JOB IN TRYCATCH'});
			if (!_isFinished) {
				finish(ProcessFinishReason.Error({error:e, stack: try{e.stack;}catch(err:Dynamic){null;}}));
			}
		}
	}
}