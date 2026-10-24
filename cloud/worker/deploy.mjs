import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {TursoStore,databaseUrl} from './turso.mjs';

export async function deploy(config,{send=fetch,asset=name=>readFile(new URL(name,import.meta.url),'utf8'),progress=()=>{},wait=ms=>new Promise(resolve=>setTimeout(resolve,ms))}={}) {
  const {worker,account,token,databaseToken,key,version}=config,database=databaseUrl(config.database);
  if(!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(worker) || !/^[a-fA-F0-9]{32}$/.test(account) || !token || !databaseToken || !/^[a-f0-9]{64}$/.test(key) || !/^\d+\.\d+\.\d+$/.test(version)) throw new Error('Set valid Cloudflare, Turso and private sync credentials.');
  const base=`https://api.cloudflare.com/client/v4/accounts/${account}`,path=`workers/scripts/${worker}`;
  async function request(url,options={}) {
    const response=await send(url,{...options,redirect:'error',signal:AbortSignal.timeout(20000)});
    return {status:response.status,data:await response.json()};
  }
  async function cf(method,route,body) {
    const r=await request(`${base}/${route}`,{method,headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});
    if(r.status<200 || r.status>=300 || r.data.success!==true) throw new Error(`Cloudflare request failed (HTTP ${r.status}).`);
    return r.data.result;
  }
  progress('Checking Cloudflare…');
  const {subdomain}=await cf('GET','workers/subdomain');
  if(!/^[a-z0-9-]+$/.test(subdomain)) throw new Error('Create your workers.dev subdomain in Cloudflare first.');
  const url=`https://${worker}.${subdomain}.workers.dev`;
  const previous=await request(`${base}/${path}/settings`,{headers:{Authorization:`Bearer ${token}`}}),existing=previous.status!==404;
  if(existing) {
    const bindings=previous.data.result?.bindings;
    if(previous.status!==200 || previous.data.success!==true || !Array.isArray(bindings) || !bindings.some(b=>b.name==='ROOM' && b.class_name==='AuralisRoom')) throw new Error('Choose a new Worker name; this name belongs to another service.');
    if(bindings.find(b=>b.name==='TURSO_DATABASE_URL')?.text!==database) throw new Error('Choose a new Worker name for a different database or a legacy sync service.');
    const auth=await request(`${url}/v1/info`,{headers:{Authorization:`Bearer ${key}`}});
    if(auth.status!==200 || auth.data.service!=='auralis-sync') throw new Error('Use the existing private sync key to redeploy.');
  }
  progress('Preparing Turso…');
  await new TursoStore({TURSO_DATABASE_URL:database,TURSO_AUTH_TOKEN:databaseToken},send).initialize();
  const metadata={main_module:'worker.mjs',compatibility_date:'2026-10-01',
    ...(!existing?{migrations:{new_tag:'v1',new_sqlite_classes:['AuralisRoom']}}:{}),
    bindings:[{type:'durable_object_namespace',name:'ROOM',class_name:'AuralisRoom'},
      {type:'plain_text',name:'AURALIS_VERSION',text:version},{type:'plain_text',name:'TURSO_DATABASE_URL',text:database},
      {type:'secret_text',name:'TURSO_AUTH_TOKEN',text:databaseToken},{type:'secret_text',name:'AURALIS_SYNC_KEY',text:key}]};
  const form=new FormData();form.set('metadata',JSON.stringify(metadata));
  for(const name of ['worker.mjs','turso.mjs']) form.set(name,new Blob([await asset(name)],{type:'application/javascript+module'}),name);
  progress('Uploading Worker…');
  const upload=await request(`${base}/${path}`,{method:'PUT',headers:{Authorization:`Bearer ${token}`},body:form});
  if(upload.status<200 || upload.status>=300 || upload.data.success!==true) throw new Error(`Worker upload failed (HTTP ${upload.status}).`);
  await cf('POST',`${path}/subdomain`,{enabled:true,previews_enabled:false});
  for(let attempt=0;attempt<6;attempt++) {
    try {
      const health=await request(`${url}/health`);
      if(health.status!==200 || health.data.service!=='auralis-sync' || !health.data.configured || health.data.backend!=='turso' || health.data.version!==version) throw new Error('Worker health check failed.');
      const probe=await request(`${url}/v1/sync`,{method:'POST',headers:{Authorization:`Bearer ${key}`,'Content-Type':'application/json'},body:'{"cursor":0,"ops":{}}'});
      if(probe.status!==200 || !probe.data.records || !Number.isSafeInteger(probe.data.cursor)) throw new Error('Worker database check failed.');
      return url;
    } catch(error) {if(attempt===5) throw error;await wait(2000);}
  }
}
if(process.argv[1] && import.meta.url===pathToFileURL(process.argv[1]).href) {
  try {
    const pubspec=await readFile(new URL('../../pubspec.yaml',import.meta.url),'utf8');
    const url=await deploy({worker:process.env.WORKER_NAME ?? 'auralis-sync',account:process.env.CLOUDFLARE_ACCOUNT_ID,
      token:process.env.CLOUDFLARE_API_TOKEN,database:process.env.TURSO_DATABASE_URL ?? '',databaseToken:process.env.TURSO_AUTH_TOKEN,
      key:process.env.AURALIS_SYNC_KEY,version:/^version:\s*(\d+\.\d+\.\d+)\+/m.exec(pubspec)?.[1]}, {progress:message=>process.stdout.write(message+'\n')});
    process.stdout.write(`Auralis sync deployed: ${url}\n`);
  } catch {process.stderr.write('Deployment failed. Check Cloudflare permissions, Turso URL/write token, existing Worker identity and private sync key.\n');process.exitCode=1;}
}
