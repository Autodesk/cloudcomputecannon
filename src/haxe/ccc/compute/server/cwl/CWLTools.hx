package ccc.compute.server.cwl;

class CWLTools
{
	public static var CWL_RUNNER_IMAGE = 'docker.io/dionjwa/cwltool-ccc:0.0.6';

	public static function workflowRun(docker :Docker, rpc :RpcRoutes, git :String, sha :String, cwl:String, input :String, ?inputs :DynamicAccess<String>) :Promise<JobResult>
	{
		return getContainerAlias(docker)
			.pipe(function(containerAlias) {
				var inputs = inputs == null ? [] :
					inputs.keys().map(function(key) {
						var input :ComputeInputSource = {
							name: key,
							type: InputSource.InputInline,
							value: inputs.get(key)
						};
						return input;
					});


				var request :BasicBatchProcessRequest = {
					image: CWL_RUNNER_IMAGE,
					inputs: inputs,
					createOptions: {
						Image: CWL_RUNNER_IMAGE,
						Cmd: ['/root/bin/download-run-workflow', git, sha, cwl, input],
						Env: ['CCC=http://${containerAlias}:${SERVER_DEFAULT_PORT}${SERVER_RPC_URL}'],
						HostConfig: {
							Binds: [
								'/tmp/repos:/tmp/repos:rw'
							]
						}
					},
					mountApiServer: true,//Needed to hit the CCC server
					parameters: {cpus:1, maxDuration:259200},//3 days, it's a workflow
					wait: false,
					appendStdOut: true,
					appendStdErr: true,
					meta: {
						"type": "workflow",
						"job-type": "workflow"
					}
				};
				return rpc.submitJobJson(request);
			});
	}

	// public static function testWorkflow(injector :Injector) :Promise<Bool>
	// {
	// 	var test = new TestCWLApi();
	// 	injector.injectInto(test);
	// 	return test.testWorkflowDynamicInput();
	// }

	static function getContainerAlias(docker :Docker) :Promise<String>
	{
		var container = docker.getContainer(DOCKER_CONTAINER_ID);
		return DockerPromises.inspect(container)
			.then(function(data :Dynamic) {
				return Reflect.field(data.Config.Labels, 'com.docker.compose.service');
			});
	}
}