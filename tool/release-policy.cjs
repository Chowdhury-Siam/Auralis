const builds = ['android.yml','windows.yml'];
function trusted(run, repository, sha) {
  return run.head_sha === sha && run.head_branch === 'main' && run.head_repository?.full_name === repository && ['push','workflow_dispatch'].includes(run.event);
}
async function resolve(github, context) {
  const {owner,repo}=context.repo, repository=`${owner}/${repo}`, trigger=context.payload.workflow_run;
  const sha=trigger?.head_sha ?? context.sha;
  if(!/^[a-f0-9]{40}$/.test(sha) || (trigger && (!trusted(trigger,repository,sha) || trigger.conclusion!=='success'))) return {ready:false};
  const compare=await github.request('GET /repos/{owner}/{repo}/compare/{basehead}',{owner,repo,basehead:`${sha}...main`});
  if(!['ahead','identical'].includes(compare.data.status)) throw new Error('Build commit is not on main');
  const selected={head_sha:sha,ready:true};
  for(const workflow_id of builds) {
    const runs=await github.paginate(github.rest.actions.listWorkflowRuns,{owner,repo,workflow_id,head_sha:sha,status:'completed',per_page:100});
    const matching=runs.filter(r=>trusted(r,repository,sha)&&r.conclusion==='success').sort((a,b)=>b.id-a.id);
    let chosen;
    for(const run of matching) {
      const artifacts=await github.paginate(github.rest.actions.listWorkflowRunArtifacts,{owner,repo,run_id:run.id,per_page:100});
      const artifact=artifacts.find(a=>!a.expired && (workflow_id==='windows.yml' ? a.name==='auralis-windows-x64' : /^auralis-android-arm64-v8a-(release|development)$/.test(a.name)));
      if(workflow_id==='android.yml' && !selected.x64_run) {
        const x64=artifacts.find(a=>!a.expired && /^auralis-android-x86_64-(release|development)$/.test(a.name));
        if(x64) {selected.x64_run=run.id;selected.x64_artifact=x64.name;selected.x64_signed=x64.name.endsWith('-release');}
      }
      if(artifact && !chosen) chosen={run,artifact};
      if(chosen && (workflow_id==='windows.yml' || selected.x64_run)) break;
    }
    if(!chosen) return {ready:false,head_sha:sha};
    if(workflow_id==='windows.yml') selected.windows_run=chosen.run.id;
    else {selected.android_run=chosen.run.id;selected.android_artifact=chosen.artifact.name;selected.signed=chosen.artifact.name.endsWith('-release');}
  }
  selected.receipt=`published-${sha}-${selected.android_run}-${selected.windows_run}${selected.x64_run?'-'+selected.x64_run:''}`;
  return selected;
}
function cleanupCandidates(runs, currentRun, now=Date.now(), publishedBuilds=new Set(), publishedCommits=new Set()) {
  const failures=new Set(['failure','timed_out','startup_failure','action_required']);
  const expired=r=>r.status==='completed' && failures.has(r.conclusion) && Number.isFinite(Date.parse(r.updated_at)) && now-Date.parse(r.updated_at)>=600000;
  const isBuild=r=>builds.some(f=>r.path===`.github/workflows/${f}`);
  const latest=new Map();
  for(const r of runs.filter(isBuild)) {
    const key=`${r.head_sha}:${r.path}`,old=latest.get(key);
    if(!old || r.id>old.id || (r.id===old.id && (r.run_attempt??1)>(old.run_attempt??1))) latest.set(key,r);
  }
  const abandoned=new Set();
  for(const r of latest.values()) {
    if(expired(r) && [...latest.values()].filter(other=>other.head_sha===r.head_sha).every(other=>other.status==='completed')) abandoned.add(r.head_sha);
  }
  return runs.filter(r=>r.id!==currentRun && r.status==='completed' && (
    (r.conclusion==='success' && (!isBuild(r) || r.head_branch !== 'main' || !['push','workflow_dispatch'].includes(r.event) || publishedBuilds.has(r.id) || publishedCommits.has(r.head_sha) || abandoned.has(r.head_sha))) || expired(r)
  )).map(r=>r.id);
}
module.exports={resolve,cleanupCandidates,trusted};
