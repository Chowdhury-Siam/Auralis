import test from 'node:test';
import assert from 'node:assert/strict';
import {deploy} from './deploy.mjs';
import {fakeTurso} from './testing/turso_backend.mjs';
const config={worker:'auralis-sync',account:'a'.repeat(32),token:'cloudflare-token',database:'libsql://auralis-test.turso.io',databaseToken:'database-token',key:'b'.repeat(64),version:'0.1.68'};
function fixture({existing=false,foreign=false,database='https://auralis-test.turso.io',wrongKey=false,uploadFails=false,accounts=false}={}) {
  const turso=fakeTurso(),calls=[];let uploaded=false,metadata;
  const send=async(url,options={})=>{
    calls.push({url,options});
    if(url.startsWith('https://auralis-test.turso.io/')) return turso.send(url,options);
    if(url.includes('api.cloudflare.com')) {
      assert.equal(options.headers.Authorization,'Bearer cloudflare-token');
      if(url.endsWith('/workers/subdomain')) return Response.json({success:true,result:{subdomain:'test-account'}});
      if(url.endsWith('/settings')) return Response.json(existing?{success:true,result:{bindings:foreign?[]:[{name:'ROOM',class_name:'AuralisRoom'},{name:'TURSO_DATABASE_URL',text:database}]}}:{success:false},{status:existing?200:404});
      if(options.method==='PUT') {
        metadata=JSON.parse(options.body.get('metadata'));assert.equal(options.body.get('worker.mjs').type,'application/javascript+module');assert.ok(options.body.get('turso.mjs'));assert.ok(options.body.get('accounts.mjs'));
        uploaded=!uploadFails;return Response.json({success:uploaded},{status:uploaded?200:403});
      }
      if(url.endsWith('/subdomain')) return Response.json({success:true,result:{enabled:true}});
    }
    if(url.endsWith('/v1/info')) return Response.json(wrongKey?{error:'bad key'}:{service:'auralis-sync'},{status:wrongKey?401:200});
    if(url.endsWith('/health')) return Response.json({service:'auralis-sync',version:config.version,configured:uploaded,backend:'turso',accounts});
    if(url.endsWith('/v1/bootstrap/deployment'))return Response.json({ok:true});
    if(url.endsWith('/v1/sync')) {assert.ok(uploaded,'old service database is not required to check ownership');return Response.json({cursor:0,more:false,records:{}});}
    throw new Error('Unexpected API request');
  };
  return {send,calls,turso,get metadata(){return metadata;},options:{send,asset:async()=> 'export class AuralisRoom {}',wait:async()=>{}}};
}
test('fresh deployment prepares Turso and uploads code with all bindings atomically',async()=>{
  const f=fixture();const url=await deploy(config,f.options);
  assert.equal(url,'https://auralis-sync.test-account.workers.dev');
  assert.deepEqual(f.metadata.migrations,{new_tag:'v1',new_sqlite_classes:['AuralisRoom']});
  assert.equal(f.metadata.bindings.find(b=>b.name==='TURSO_AUTH_TOKEN').type,'secret_text');
  assert.equal(f.metadata.bindings.find(b=>b.name==='AURALIS_SYNC_KEY').text,config.key);
  assert.ok(f.turso.db.prepare('SELECT * FROM auralis_meta').get());f.turso.db.close();
});
test('redeploy authenticates existing key and preserves namespace without new migration',async()=>{
  const f=fixture({existing:true});await deploy(config,f.options);assert.equal(f.metadata.migrations,undefined);assert.ok(f.calls.some(c=>c.url.endsWith('/v1/info')));f.turso.db.close();
});
test('foreign Worker, changed database, legacy deployment and wrong sync key are refused before writes',async()=>{
  for(const flags of [{existing:true,foreign:true},{existing:true,database:'https://other.turso.io'},{existing:true,database:undefined,foreign:true},{existing:true,wrongKey:true}]) {
    const f=fixture(flags);await assert.rejects(()=>deploy(config,f.options));assert.equal(f.turso.calls,0);assert.equal(f.calls.some(c=>c.options.method==='PUT'),false);f.turso.db.close();
  }
});
test('invalid URL and failed schema/upload never report a successful deployment',async()=>{
  const invalid=fixture();await assert.rejects(()=>deploy({...config,database:'https://evil.example'},invalid.options));assert.equal(invalid.calls.length,0);invalid.turso.db.close();
  const schema=fixture();schema.turso.fail=()=>true;await assert.rejects(()=>deploy(config,schema.options));assert.equal(schema.calls.some(c=>c.options.method==='PUT'),false);schema.turso.db.close();
  const upload=fixture({uploadFails:true});await assert.rejects(()=>deploy(config,upload.options));assert.equal(upload.calls.some(c=>c.url.endsWith('/v1/sync')),false);upload.turso.db.close();
});

test('account deployment installs JWT secret and saves encrypted recovery configuration',async()=>{
 const f=fixture({accounts:true});await deploy(config,f.options);
 assert.equal(f.metadata.bindings.find(b=>b.name==='JWT_SECRET').text,config.key);
 const request=f.calls.find(c=>c.url.endsWith('/v1/bootstrap/deployment'));
 assert.equal(JSON.parse(request.options.body).cloudflareToken,config.token);
 assert.equal(request.options.headers.Authorization,'Bearer '+config.key);f.turso.db.close();
});
