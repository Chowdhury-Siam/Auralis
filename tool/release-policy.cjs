const builds = ['android.yml','windows.yml'];
function trusted(run, repository, sha) {
  return run.head_sha === sha && run.head_branch === 'main' && run.head_repository?.full_name === repository && ['push','workflow_dispatch'].includes(run.event);
}
function publishedAndroid(release, version, abi, bundle) {
  if (!bundle) return false;
  const signed = bundle.artifact.name.endsWith('-release');
  const mode = signed ? 'release' : 'development-release';
  const suffix = signed ? '' : '-development';
  const assets = new Set(release.assets.map(asset => asset.name));
  return [
    `auralis-${version}-android-${abi}-${mode}.apk`,
    `auralis-${version}-android-${abi}${suffix}-provenance.zip`,
    `SHA256SUMS-android-${abi}${suffix}.txt`,
  ].every(name => assets.has(name));
}

async function resolve(github, context, {allowAndroidOnly = false} = {}) {
  const {owner, repo} = context.repo;
  const repository = `${owner}/${repo}`;
  const trigger = context.payload.workflow_run;
  const sha = trigger?.head_sha ?? context.sha;
  if (!/^[a-f0-9]{40}$/.test(sha) ||
      (trigger && (!trusted(trigger, repository, sha) || trigger.conclusion !== 'success'))) {
    return {ready: false};
  }
  const compare = await github.request('GET /repos/{owner}/{repo}/compare/{basehead}', {
    owner, repo, basehead: `${sha}...main`,
  });
  if (!['ahead', 'identical'].includes(compare.data.status)) {
    throw new Error('Build commit is not on main');
  }
  const {data: manifest} = await github.rest.repos.getContent({
    owner, repo, ref: sha, path: 'pubspec.yaml',
  });
  const version = Buffer.from(manifest.content, 'base64').toString('utf8')
    .match(/^version:\s*((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))\+\d+\s*$/m)?.[1];
  if (!version) throw new Error('Build commit needs a stable pubspec version');
  const tag = `v${version}`;
  let release;
  try {
    ({data: release} = await github.rest.repos.getReleaseByTag({owner, repo, tag}));
  } catch (error) {
    if (error.status !== 404) throw error;
  }
  if (release?.prerelease) throw new Error(`${tag} is already a prerelease`);
  const stable = release?.draft === false;
  // A rerun can use the older publisher YAML with the current main policy.
  if (stable && !allowAndroidOnly) {
    return {ready: false, head_sha: sha, reason: `${tag} is already stable.`};
  }

  let android, x64, windows;
  for (const workflow_id of builds) {
    // The Windows bundle has already been published for a stable release.
    if (stable && workflow_id === 'windows.yml') continue;
    const runs = await github.paginate(github.rest.actions.listWorkflowRuns, {
      owner, repo, workflow_id, head_sha: sha, status: 'completed', per_page: 100,
    });
    const matching = runs.filter(r => trusted(r, repository, sha) && r.conclusion === 'success')
      .sort((a, b) => b.id - a.id);
    for (const run of matching) {
      let artifacts;
      try {
        artifacts = await github.paginate(github.rest.actions.listWorkflowRunArtifacts, {
          owner, repo, run_id: run.id, per_page: 100,
        });
      } catch (error) {
        if (error.status === 404) continue;
        throw error;
      }
      const available = artifacts.filter(a => !a.expired);
      if (workflow_id === 'windows.yml') {
        const artifact = available.find(a => a.name === 'auralis-windows-x64');
        if (artifact) {
          windows = {run, artifact};
          break;
        }
      } else {
        const arm64 = available.find(a => /^auralis-android-arm64-v8a-(release|development)$/.test(a.name));
        const optional = available.find(a => /^auralis-android-x86_64-(release|development)$/.test(a.name));
        if (arm64 && !android) android = {run, artifact: arm64};
        if (optional && !x64) x64 = {run, artifact: optional};
        if (android && x64) break;
      }
    }
  }

  if (!stable && (!android || !windows)) return {ready: false, head_sha: sha};
  if (stable) {
    if (publishedAndroid(release, version, 'arm64-v8a', android)) android = undefined;
    if (publishedAndroid(release, version, 'x86_64', x64)) x64 = undefined;
    if (!android && !x64) {
      return {
        ready: false,
        head_sha: sha,
        reason: `${tag} is already stable. No additional Android bundles are available to publish.`,
      };
    }
  }
  const receipt = `published-${sha}-${android?.run.id ?? 0}-${windows?.run.id ?? 0}${x64 ? '-' + x64.run.id : ''}`;
  return {
    ready: true,
    head_sha: sha,
    windows_run: windows?.run.id ?? '',
    windows_artifact_id: windows?.artifact.id ?? '',
    android_run: android?.run.id ?? '',
    android_artifact: android?.artifact.name ?? '',
    android_artifact_id: android?.artifact.id ?? '',
    signed: android?.artifact.name.endsWith('-release') ?? false,
    x64_run: x64?.run.id ?? '',
    x64_artifact: x64?.artifact.name ?? '',
    x64_artifact_id: x64?.artifact.id ?? '',
    x64_signed: x64?.artifact.name.endsWith('-release') ?? false,
    receipt,
  };
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
    r.conclusion==='skipped' || (r.conclusion==='success' && (!isBuild(r) || r.head_branch !== 'main' || !['push','workflow_dispatch'].includes(r.event) || publishedBuilds.has(r.id) || publishedCommits.has(r.head_sha) || abandoned.has(r.head_sha))) || expired(r)
  )).map(r=>r.id);
}
module.exports={resolve,cleanupCandidates,trusted};
