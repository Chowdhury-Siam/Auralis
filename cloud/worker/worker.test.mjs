import test from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import worker,{AuralisRoom,merge} from './worker.mjs';
const actor='a'.repeat(32), other='b'.repeat(32), key=JSON.stringify;
const r=(value,clock=1,device=actor)=>({value,clock,device});
function backend() {
 const db=new DatabaseSync(':memory:');
 const state={getWebSockets:()=>[],storage:{
  sql:{exec(sql,...values){const s=db.prepare(sql);return s.columns().length?s.all(...values):(s.run(...values),[]);}},
  transactionSync(fn){db.exec('BEGIN');try{const v=fn();db.exec('COMMIT');return v;}catch(e){db.exec('ROLLBACK');throw e;}}
 }};
 return {room:new AuralisRoom(state),db,state};
}
async function sync(room,ops={},cursor=0) {
 const response=await room.fetch(new Request('https://example.com/v1/sync',{method:'POST',body:JSON.stringify({ops,cursor})}));
 return {status:response.status,body:await response.json()};
}
test('offline additions merge, tombstones win and retries do not duplicate revisions',async()=>{
 const {room,db}=backend();
 const a=key(['favorite','a']),b=key(['favorite','b']);
 let response=await sync(room,{[a]:r(true),[b]:r(true,1,other)});assert.equal(response.status,200);assert.equal(Object.keys(response.body.records).length,2);
 response=await sync(room,{[a]:r(null,2)},response.body.cursor);assert.equal(response.body.records[a].value,null);
 const cursor=response.body.cursor;
 response=await sync(room,{[a]:r(true,1)});assert.equal(response.body.records[a].value,null);assert.equal(response.body.cursor,cursor);
 db.close();
});
test('per-device listening counters and shared baseline merge by maximum',()=>{
 const stats={milliseconds:100,plays:1,title:'Song',artist:'Artist',source:'Channel',lastListened:null};
 const k=key(['stats','baseline','song']);
 const result=merge(k,r(stats),r({...stats,milliseconds:50},2,other));assert.equal(result.value.milliseconds,100);assert.equal(result.value.plays,1);
 assert.deepEqual(merge(k,result,r(stats)),result);
});
test('different playlist entries survive concurrent edits and server restart',async()=>{
 const {room,db,state}=backend();
 const a=key(['entry','Mix','a']),b=key(['entry','Mix','b']);
 await sync(room,{[a]:r(0)});await sync(room,{[b]:r(1,1,other)});
 const response=await sync(new AuralisRoom(state));assert.equal(response.body.records[a].value,0);assert.equal(response.body.records[b].value,1);db.close();
});
test('invalid fields and oversized batches are rejected atomically',async()=>{
 const {room,db}=backend();
 const bad={[key(['favorite','good'])]:r(true),[key(['credentials','secret'])]:r('bad')};
 assert.equal((await sync(room,bad)).status,400);
 assert.equal(Object.keys((await sync(room)).body.records).length,0);
 assert.equal((await sync(room,Object.fromEntries(Array.from({length:101},(_,i)=>[key(['favorite',String(i)]),r(true)])))).status,400);
 assert.equal((await sync(room,{},999)).status,400);db.close();
});
test('change feed paginates without losing writes and resending is idempotent',async()=>{
 const {room,db}=backend();
 for(let n=0;n<3;n++) await sync(room,Object.fromEntries(Array.from({length:100},(_,i)=>[key(['favorite',String(n*100+i)]),r(true)])));
 const first=(await sync(room)).body;assert.equal(Object.keys(first.records).length,200);assert.equal(first.more,true);
 const second=(await sync(room,{},first.cursor)).body;assert.equal(Object.keys(second.records).length,100);assert.equal(second.more,false);
 const empty=(await sync(room,{},second.cursor)).body;assert.equal(Object.keys(empty.records).length,0);db.close();
});
test('authorization is required before any durable object access',async()=>{
 let calls=0;const env={AURALIS_SYNC_KEY:'a'.repeat(64),ROOM:{idFromName:()=>1,get:()=>({fetch:()=>{calls++;return Response.json({ok:true});}})}};
 assert.equal((await worker.fetch(new Request('https://example.com/v1/sync'),env)).status,401);assert.equal(calls,0);
 assert.equal((await worker.fetch(new Request('https://example.com/v1/sync',{headers:{Authorization:'Bearer '+'a'.repeat(64)}}),env)).status,200);assert.equal(calls,1);
 const health=await (await worker.fetch(new Request('https://example.com/health'),env)).json();assert.equal(health.service,'auralis-sync');assert.equal(JSON.stringify(health).includes(env.AURALIS_SYNC_KEY),false);
});
test('partial Turso configuration cannot fall back locally and ownership remains verifiable for repair',async()=>{
 const env={AURALIS_SYNC_KEY:'a'.repeat(64),TURSO_DATABASE_URL:'https://auralis-test.turso.io',ROOM:{get(){throw new Error('must not reach local data');}}};
 const headers={Authorization:'Bearer '+env.AURALIS_SYNC_KEY};
 assert.equal((await worker.fetch(new Request('https://example.com/v1/sync',{headers}),env)).status,503);
 assert.equal((await worker.fetch(new Request('https://example.com/v1/info',{headers}),env)).status,200);
 assert.equal((await (await worker.fetch(new Request('https://example.com/health'),env)).json()).configured,false);
});

test('SQLite failure rolls back the entire batch and revision',async()=>{
 const {room,db,state}=backend();const original=state.storage.sql.exec;let inserts=0;
 state.storage.sql.exec=(sql,...values)=>{if(sql.startsWith('INSERT INTO records') && ++inserts===2)throw new Error('injected storage failure');return original(sql,...values);};
 const result=await sync(room,{[key(['favorite','one'])]:r(true),[key(['favorite','two'])]:r(true)});
 assert.equal(result.status,400);state.storage.sql.exec=original;
 const empty=await sync(room);assert.equal(Object.keys(empty.body.records).length,0);assert.equal(empty.body.cursor,0);db.close();
});
