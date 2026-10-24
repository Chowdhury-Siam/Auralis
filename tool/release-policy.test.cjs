const {test}=require('node:test');const assert=require('node:assert/strict');
const {cleanupCandidates,resolve,trusted}=require('./release-policy.cjs');
const sha='a'.repeat(40),repo='Owner/Auralis',now=Date.now();
const run=(id,path,conclusion='success',age=0)=>({id,path:`.github/workflows/${path}`,status:'completed',conclusion,updated_at:new Date(now-age).toISOString(),head_sha:sha,head_branch:'main',head_repository:{full_name:repo},event:'push'});
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
 const github={request:async()=>({data:{status:'identical'}}),rest:{actions:{listWorkflowRuns:'runs',listWorkflowRunArtifacts:'artifacts'}},paginate:async(type,params)=>type==='runs'?(params.workflow_id==='android.yml'?[a]:[w]):[{name:params.run_id===1?'auralis-android-arm64-v8a-release':'auralis-windows-x64',expired:false}]};
 const context={repo:{owner:'Owner',repo:'Auralis'},sha,payload:{workflow_run:a}};
 assert.equal((await resolve(github,context)).ready,true);
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
 const github={request:async()=>({data:{status:'ahead'}}),rest:{actions:{listWorkflowRuns:'runs',listWorkflowRunArtifacts:'artifacts'}},paginate:async(type,p)=>type==='runs'?(p.workflow_id==='android.yml'?[x,a]:[w]):[{name:artifacts[p.run_id],expired:false}]};
 const result=await resolve(github,{repo:{owner:'Owner',repo:'Auralis'},sha,payload:{workflow_run:x}});
 assert.equal(result.ready,true);assert.equal(result.android_run,1);assert.equal(result.windows_run,2);assert.equal(result.x64_run,3);assert.equal(result.x64_signed,false);
 assert.equal(result.receipt,`published-${sha}-1-2-3`);
});
test('completed green feature and pull-request runs do not retain unpublished artifacts',()=>{
 assert.deepEqual(cleanupCandidates([{...run(9,'android.yml'),event:'pull_request',head_branch:'feature'}],0,now),[9]);
});
