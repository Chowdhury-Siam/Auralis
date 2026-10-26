import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {TursoStore,schema,databaseUrl} from './turso.mjs';
import {merge,AuralisRoom} from './worker.mjs';
import {fakeTurso} from './testing/turso_backend.mjs';
const env={TURSO_DATABASE_URL:'libsql://auralis-test.turso.io',TURSO_AUTH_TOKEN:'database-token'};
const record=(value,clock=1,device='a'.repeat(32))=>({clock,device,value});
const key=JSON.stringify;
async function setup(){const backend=fakeTurso(),store=new TursoStore(env,backend.send);await store.initialize();return {...backend,store,backend};}
test('bundled SQL matches the runtime schema and URL validation blocks credential redirects',async()=>{
  assert.deepEqual((await readFile(new URL('schema.sql',import.meta.url),'utf8')).split(';').map(s=>s.trim()).filter(Boolean),schema);
  assert.equal(databaseUrl(env.TURSO_DATABASE_URL),'https://auralis-test.turso.io');
  for(const value of ['http://auralis-test.turso.io','https://other.example','https://a.turso.io@evil.example','libsql://a.turso.io:443','libsql://a.turso.io/path']) assert.throws(()=>databaseUrl(value));
});
test('Turso persists changes across room/store restart, tombstones and retries converge',async()=>{
  const {store,db,backend}=await setup(),k=key(['favorite','song']);
  let result=await store.sync({cursor:0,ops:{[k]:record(true)}},merge);
  assert.equal(result.output.cursor,1);
  result=await store.sync({cursor:0,ops:{[k]:record(true)}},merge);assert.equal(result.changed,false);assert.equal(result.output.cursor,1);
  const restarted=new TursoStore(env,backend.send);await restarted.initialize();
  result=await restarted.sync({cursor:0,ops:{[k]:record(null,2)}},merge);
  assert.equal(result.output.records[k].value,null);assert.equal(result.output.cursor,2);db.close();
});
test('Turso transactions roll back all records and the cursor on any failed write',async()=>{
  const {store,db,backend}=await setup();let inserts=0;
  backend.fail=sql=>sql.startsWith('INSERT INTO auralis_records') && ++inserts===2;
  await assert.rejects(()=>store.sync({cursor:0,ops:{[key(['favorite','a'])]:record(true),[key(['favorite','b'])]:record(true)}},merge));
  backend.fail=null;
  const result=await store.sync({cursor:0,ops:{}},merge);assert.equal(result.output.cursor,0);assert.deepEqual(result.output.records,{});db.close();
});
test('optimistic revision guard retries a competing writer without losing its record',async()=>{
  const {store,db,backend}=await setup();let injected=false;
  const foreign=key(['favorite','other']);
  backend.beforeBatch=batch=>{
    if(!injected && batch.steps.some(s=>s.stmt.sql.startsWith('UPDATE auralis_meta'))) {
      injected=true;db.prepare('INSERT INTO auralis_records VALUES(?,?,1)').run(foreign,JSON.stringify(record(true,1,'b'.repeat(32))));db.exec('UPDATE auralis_meta SET revision=1');
    }
  };
  const result=await store.sync({cursor:0,ops:{[key(['favorite','local'])]:record(true)}},merge);
  assert.equal(result.output.cursor,2);assert.equal(Object.keys(result.output.records).length,2);db.close();
});
test('Turso pagination, listening maxima and independent playlist edits survive',async()=>{
  const {store,db}=await setup();
  for(let page=0;page<3;page++) await store.sync({cursor:0,ops:Object.fromEntries(Array.from({length:100},(_,i)=>[key(['entry','Mix',String(page*100+i)]),record(i)]))},merge);
  const first=await store.sync({cursor:0,ops:{}},merge);assert.equal(first.output.more,true);assert.equal(Object.keys(first.output.records).length,200);
  const second=await store.sync({cursor:first.output.cursor,ops:{}},merge);assert.equal(Object.keys(second.output.records).length,100);
  const k=key(['day','baseline','2026-10-24']);await store.sync({cursor:0,ops:{[k]:record({milliseconds:100,plays:1})}},merge);
  const result=await store.sync({cursor:second.output.cursor,ops:{[k]:record({milliseconds:50,plays:0},2)}},merge);assert.equal(result.output.records[k].value.milliseconds,100);db.close();
});
test('Turso errors never fall back to a different local store or notify peers before commit',async()=>{
  const db=fakeTurso(),local=fakeTurso();
  let notifications=0;
  const state={getWebSockets:()=>[{send(){notifications++;}}],storage:{sql:{exec(sql,...args){const s=local.db.prepare(sql);return s.columns().length?s.all(...args):(s.run(...args),[]);}}}};
  const room=new AuralisRoom(state);room.turso=new TursoStore(env,db.send);db.fail=()=>true;
  const response=await room.fetch(new Request('https://example.com/v1/sync',{method:'POST',body:JSON.stringify({cursor:0,ops:{[key(['favorite','song'])]:record(true)}})}));
  assert.equal(response.status,503);assert.equal(notifications,0);assert.equal(local.db.prepare('SELECT count(*) AS n FROM records').get().n,0);
  assert.equal((await response.text()).includes('database-token'),false);local.db.close();db.db.close();
});
test('real room handler serializes Turso writes and notifies only committed remote records',async()=>{
  const remote=fakeTurso(),local=fakeTurso();let notifications=0;
  const state={getWebSockets:()=>[{send(){assert.ok(remote.db.prepare('SELECT count(*) AS n FROM auralis_records').get().n>0);notifications++;}}],storage:{sql:{exec(sql,...args){const s=local.db.prepare(sql);return s.columns().length?s.all(...args):(s.run(...args),[]);}}}};
  const make=()=>{const room=new AuralisRoom(state,env);room.turso=new TursoStore(env,remote.send);return room;};
  const room=make();
  const request=ops=>new Request('https://example.com/v1/sync',{method:'POST',body:JSON.stringify({cursor:0,ops})});
  const responses=await Promise.all([room.fetch(request({[key(['favorite','one'])]:record(true)})),room.fetch(request({[key(['favorite','two'])]:record(true)}))]);
  assert.ok(responses.every(r=>r.status===200));assert.equal(notifications,2);
  const restored=await (await make().fetch(request({}))).json();
  assert.equal(Object.keys(restored.records).length,2);assert.equal(restored.cursor,2);assert.equal(notifications,2);
  assert.equal(local.db.prepare('SELECT count(*) AS n FROM records').get().n,0);remote.db.close();local.db.close();
});
test('account table scopes isolate records and delete only the selected account',async()=>{
 const remote=fakeTurso(),a=new TursoStore(env,remote.send,'a'.repeat(32)),b=new TursoStore(env,remote.send,'b'.repeat(32));
 await a.initialize();await b.initialize();const k=key(['favorite','private']);
 await a.sync({cursor:0,ops:{[k]:record(true)}},merge);
 assert.deepEqual((await b.sync({cursor:0,ops:{}},merge)).output.records,{});
 await b.sync({cursor:0,ops:{[k]:record(true)}},merge);await a.clear();
 assert.deepEqual((await a.sync({cursor:0,ops:{}},merge)).output.records,{});
 assert.equal((await b.sync({cursor:0,ops:{}},merge)).output.records[k].value,true);remote.db.close();
});
