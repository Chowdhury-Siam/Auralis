const {test}=require('node:test');const assert=require('node:assert/strict');
const {cleanupCandidates,resolve,trusted}=require('./release-policy.cjs');
const sha='a'.repeat(40),repo='Owner/Auralis',now=Date.now();
const run=(id,path,conclusion='success',age=0)=>({id,path:`.github/workflows/${path}`,status:'completed',conclusion,updated_at:new Date(now-age).toISOString(),head_sha:sha,head_branch:'main',head_repository:{full_name:repo},event:'push'});
function releaseApi(release) {
  return {
    getContent: async ({ref, path}) => {
      assert.equal(ref, sha);
      assert.equal(path, 'pubspec.yaml');
      return {data: {content: Buffer.from('version: 0.1.118+119\n').toString('base64')}};
    },
    getReleaseByTag: async ({tag}) => {
      assert.equal(tag, 'v0.1.118');
      if (release) return {data: release};
      throw Object.assign(new Error('Not Found'), {status: 404});
    },
  };
}
test('cleanup preserves unpublished builds, active runs and failures younger than ten minutes',()=>{
 const runs=[run(1,'android.yml'),run(2,'windows.yml'),run(3,'publish-release.yml'),run(4,'android.yml','failure',599999),run(5,'windows.yml','failure',600000),{...run(6,'windows.yml'),status:'in_progress'},run(7,'cleanup-runs.yml')];
 assert.deepEqual(cleanupCandidates(runs,7,now,new Set()),[3,5]);
 assert.deepEqual(cleanupCandidates(runs,7,now,new Set([1,2])),[1,2,3,5]);
});
test('completed skipped runs are cleaned without waiting while current, active and cancelled runs stay',()=>{
 const runs=[run(1,'publish-release.yml','skipped'),run(2,'android.yml','skipped'),run(3,'windows.yml','skipped'),run(4,'cleanup-runs.yml','skipped'),{...run(5,'publish-release.yml','skipped'),status:'in_progress'},{...run(6,'android.yml','skipped'),status:'queued'},run(7,'windows.yml','cancelled'),run(8,'android.yml'),run(9,'windows.yml','failure',599999)];
 assert.deepEqual(cleanupCandidates(runs,4,now),[1,2,3]);
});
test('foreign repositories, branches and pull requests cannot authorize publication',()=>{
 assert.equal(trusted(run(1,'android.yml'),repo,sha),true);
 for(const change of [{head_branch:'feature'},{event:'pull_request'},{head_repository:{full_name:'Other/Auralis'}},{head_sha:'b'.repeat(40)}]) assert.equal(trusted({...run(1,'android.yml'),...change},repo,sha),false);
});
test('publisher waits for both exact commit artifacts and never mixes commits',async()=>{
 const a=run(1,'android.yml'),w=run(2,'windows.yml');
 const github={request:async()=>({data:{status:'identical'}}),rest:{repos:releaseApi(),actions:{listWorkflowRuns:'runs',listWorkflowRunArtifacts:'artifacts'}},paginate:async(type,params)=>type==='runs'?(params.workflow_id==='android.yml'?[a]:[w]):[{id:params.run_id+10,name:params.run_id===1?'auralis-android-arm64-v8a-release':'auralis-windows-x64',expired:false}]};
 const context={repo:{owner:'Owner',repo:'Auralis'},sha,payload:{workflow_run:a}};
 const selected = await resolve(github, context);
 assert.equal(selected.ready, true);
 assert.equal(selected.windows_artifact_id, 12);
 assert.equal(selected.android_artifact_id, 11);
 assert.equal(selected.android_artifact, 'auralis-android-arm64-v8a-release');
 w.head_sha='b'.repeat(40);assert.equal((await resolve(github,context)).ready,false);
});

test('an abandoned failed commit is cleaned after ten minutes, but an active retry preserves its artifacts',()=>{
 const runs=[run(1,'android.yml'),run(2,'windows.yml','failure',600000)];
 assert.deepEqual(cleanupCandidates(runs,0,now),[1,2]);
 const retry={...run(3,'windows.yml'),status:'in_progress',conclusion:null};
 assert.deepEqual(cleanupCandidates([...runs,retry],0,now),[2]);
 assert.deepEqual(cleanupCandidates([run(1,'android.yml')],0,now,new Set(),new Set([sha])),[1]);
});

test('optional x64 artifacts join the same-commit release and receipt',async()=>{
 const a=run(1,'android.yml'),w=run(2,'windows.yml'),x=run(3,'android.yml');
 const artifacts={1:'auralis-android-arm64-v8a-release',2:'auralis-windows-x64',3:'auralis-android-x86_64-development'};
 const github={request:async()=>({data:{status:'ahead'}}),rest:{repos:releaseApi(),actions:{listWorkflowRuns:'runs',listWorkflowRunArtifacts:'artifacts'}},paginate:async(type,p)=>type==='runs'?(p.workflow_id==='android.yml'?[x,a]:[w]):[{id:p.run_id+10,name:artifacts[p.run_id],expired:false}]};
 const result=await resolve(github,{repo:{owner:'Owner',repo:'Auralis'},sha,payload:{workflow_run:x}});
 assert.equal(result.ready,true);assert.equal(result.android_run,1);assert.equal(result.windows_run,2);assert.equal(result.x64_run,3);assert.equal(result.x64_signed,false);
 assert.equal(result.receipt,`published-${sha}-1-2-3`);
});
test('a duplicate publisher skips the already stable release after cleanup', async () => {
  const existing = {draft: false, prerelease: false, assets: []};
  const android = run(1, 'android.yml');
  const github = {
    request: async () => ({data: {status: 'identical'}}),
    rest: {repos: releaseApi(existing), actions: {
      listWorkflowRuns: 'runs', listWorkflowRunArtifacts: 'artifacts',
    }},
    paginate: async (type, params) => {
      if (type === 'runs') {
        assert.equal(params.workflow_id, 'android.yml', 'The Windows bundle was already published');
        return [android];
      }
      // Cleanup can have deleted a run that was still visible in a listing.
      throw Object.assign(new Error('Not Found'), {status: 404});
    },
  };
  const context = {repo: {owner: 'Owner', repo: 'Auralis'}, sha, payload: {}};
  const result = await resolve(github, context, {allowAndroidOnly: true});
  assert.equal(result.ready, false);
  assert.match(result.reason, /v0.1.118 is already stable/);
});

test('an available x64 bundle can supplement a stable release after Windows cleanup', async () => {
  const arm = run(1, 'android.yml');
  const x64 = run(3, 'android.yml');
  const existing = {
    draft: false, prerelease: false,
    assets: [
      'auralis-0.1.118-android-arm64-v8a-release.apk',
      'auralis-0.1.118-android-arm64-v8a-provenance.zip',
      'SHA256SUMS-android-arm64-v8a.txt',
    ].map(name => ({name})),
  };
  const github = {
    request: async () => ({data: {status: 'identical'}}),
    rest: {repos: releaseApi(existing), actions: {
      listWorkflowRuns: 'runs', listWorkflowRunArtifacts: 'artifacts',
    }},
    paginate: async (type, params) => {
      if (type === 'runs') {
        assert.equal(params.workflow_id, 'android.yml');
        return [arm, x64];
      }
      const abi = params.run_id === 1 ? 'arm64-v8a' : 'x86_64';
      return [{id: 10 + params.run_id, name: `auralis-android-${abi}-release`, expired: false}];
    },
  };
  const context = {repo: {owner: 'Owner', repo: 'Auralis'}, sha, payload: {workflow_run: x64}};
  assert.equal((await resolve(github, context)).ready, false, 'A legacy publisher must not download an Android-only bundle');
  const result = await resolve(github, context, {allowAndroidOnly: true});
  assert.equal(result.ready, true);
  assert.equal(result.windows_run, '');
  assert.equal(result.android_run, '');
  assert.equal(result.x64_run, 3);
  assert.equal(result.x64_artifact_id, 13);
  assert.equal(result.receipt, `published-${sha}-0-0-3`);
});
test('completed green feature and pull-request runs do not retain unpublished artifacts',()=>{
 assert.deepEqual(cleanupCandidates([{...run(9,'android.yml'),event:'pull_request',head_branch:'feature'}],0,now),[9]);
});
