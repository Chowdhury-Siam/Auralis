import test from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import worker,{AuralisRoom} from './worker.mjs';
function service(){const stores=new Map(),env={AURALIS_SYNC_KEY:'d'.repeat(64),JWT_SECRET:'d'.repeat(64),AURALIS_VERSION:'0.1.76'};env.ROOM={idFromName:n=>n,get(n){if(!stores.has(n)){const db=new DatabaseSync(':memory:'),sockets=[],state={getWebSockets:()=>sockets,storage:{sql:{exec(sql,...args){const s=db.prepare(sql);return s.columns().length?s.all(...args):(s.run(...args),[]);}},transactionSync(fn){db.exec('BEGIN');try{const result=fn();db.exec('COMMIT');return result;}catch(e){db.exec('ROLLBACK');throw e;}}}};stores.set(n,{db,sockets,room:new AuralisRoom(state,env)});}return stores.get(n).room;}};return {env,stores,async call(path,{token,data,method=data?'POST':'GET'}={}){const r=await worker.fetch(new Request('https://sync.example'+path,{method,headers:{'CF-Connecting-IP':'127.0.0.1',...(token?{Authorization:'Bearer '+token}:{})},...(data?{body:JSON.stringify(data)}:{})}),env);return {status:r.status,data:r.headers.get('content-type')?.includes('application/json')?await r.json():await r.text()};},close(){for(const {db} of stores.values())db.close();}};}
const register=(s,name='alice',claimKey='d'.repeat(64))=>s.call('/v1/auth/register',{data:{username:name,password:'test-password',claimKey}});
const record={value:true,clock:1,device:'a'.repeat(32)},key=JSON.stringify(['favorite','one']);
test('owner requires deployment proof, inherits legacy data, and later accounts are isolated',async()=>{
 const s=service();try{
 assert.equal((await s.call('/v1/sync',{token:'d'.repeat(64),data:{cursor:0,ops:{[key]:record}}})).status,200);
 assert.equal((await register(s,'alice','')).status,400);
 const a=await register(s);assert.equal(a.status,200);assert.equal(a.data.user.admin,true);
 assert.equal((await s.call('/v1/sync',{token:'d'.repeat(64),data:{cursor:0,ops:{}}})).status,401);
 assert.equal((await s.call('/v1/sync',{token:a.data.token,data:{cursor:0,ops:{}}})).data.records[key].value,true);
 const b=await register(s,'bob','');assert.equal(b.data.user.admin,false);
 assert.deepEqual((await s.call('/v1/sync',{token:b.data.token,data:{cursor:0,ops:{}}})).data.records,{});
 assert.equal((await s.call('/v1/sync',{token:b.data.token,data:{cursor:0,ops:{[key]:record}}})).status,200);
 }finally{s.close();}
});
test('deployment recovery is encrypted, owner-only and forgettable',async()=>{
 const s=service();try{const p={worker:'sync',account:'a'.repeat(32),cloudflareToken:'cf-secret',database:'libsql://test.turso.io',databaseToken:'turso-secret',key:'d'.repeat(64),automatic:true};
 assert.equal((await s.call('/v1/bootstrap/deployment',{method:'PUT',token:'d'.repeat(64),data:p})).status,200);
 const a=(await register(s)).data,b=(await register(s,'bob','')).data;
 assert.equal((await s.call('/v1/account/deployment',{token:b.token})).status,403);
 assert.equal((await s.call('/v1/account/deployment',{token:a.token})).data.deployment.cloudflareToken,'cf-secret');
 assert.equal(s.stores.get('account-registry').db.prepare("SELECT value FROM account_meta WHERE key='deployment'").get().value.includes('cf-secret'),false);
 assert.equal((await s.call('/v1/account/deployment',{method:'DELETE',token:a.token})).status,200);
 assert.equal((await s.call('/v1/account/deployment',{token:a.token})).data.deployment,null);
 }finally{s.close();}
});
test('one-use recovery rotates password and revokes old sessions',async()=>{
 const s=service();try{const a=(await register(s)).data;const r=await s.call('/v1/auth/recover',{data:{username:'alice',recoveryCode:a.recoveryCode,newPassword:'changed-password'}});assert.equal(r.status,200);assert.notEqual(r.data.recoveryCode,a.recoveryCode);
 assert.equal((await s.call('/v1/account',{token:a.token})).status,401);
 assert.equal((await s.call('/v1/auth/recover',{data:{username:'alice',recoveryCode:a.recoveryCode,newPassword:'test-password'}})).status,401);
 assert.equal((await s.call('/v1/auth/login',{data:{username:'alice',password:'test-password'}})).status,401);
 assert.equal((await s.call('/v1/auth/login',{data:{username:'alice',password:'changed-password'}})).status,200);
 }finally{s.close();}
});
test('account deletion confirms password, erases only its library, and never grants a new owner',async()=>{
 const s=service();try{const a=(await register(s)).data,b=(await register(s,'bob','')).data;
 for(const u of [a,b])await s.call('/v1/sync',{token:u.token,data:{cursor:0,ops:{[key]:record}}});
 assert.equal((await s.call('/v1/account',{method:'DELETE',token:a.token,data:{password:'wrong'}})).status,401);
 assert.equal((await s.call('/v1/account',{method:'DELETE',token:a.token,data:{password:'test-password'}})).status,200);
 assert.equal((await s.call('/v1/account',{token:a.token})).status,401);
 assert.equal((await s.call('/v1/sync',{token:b.token,data:{cursor:0,ops:{}}})).data.records[key].value,true);
 assert.equal((await register(s,'charlie','')).data.user.admin,false);
 }finally{s.close();}
});
test('logout closes only its session sockets and admin reset revokes another account',async()=>{
 const s=service();try{const a=(await register(s)).data,b=(await register(s,'bob','')).data;let closed=0;
 s.stores.get('account-bogus');const room=s.env.ROOM.get(s.env.ROOM.idFromName(b.user.room));assert.ok(room);
 const db=s.stores.get('account-registry').db,jti=db.prepare('SELECT id FROM sessions WHERE account=?').get(b.user.id).id;
 s.stores.get(b.user.room).sockets.push({deserializeAttachment:()=>({session:jti}),close(){closed++;}});
 assert.equal((await s.call('/v1/auth/logout',{token:b.token,data:{}})).status,200);assert.equal(closed,1);assert.equal((await s.call('/v1/account',{token:b.token})).status,401);
 const reset=await s.call('/v1/admin/reset',{token:a.token,data:{username:'bob',newPassword:'other-password'}});assert.equal(reset.status,200);assert.equal(reset.data.recoveryCode.length,64);
 assert.equal((await s.call('/v1/auth/login',{data:{username:'bob',password:'other-password'}})).status,200);
 const page=await worker.fetch(new Request('https://sync.example/profile'),s.env);assert.match(page.headers.get('Content-Security-Policy'),/frame-ancestors 'none'/);
 }finally{s.close();}
});
test('recovery can be redeemed only once under concurrent requests; authentication is rate limited',async()=>{
 const s=service();try{const a=(await register(s)).data,data={username:'alice',recoveryCode:a.recoveryCode,newPassword:'changed-password'};
 const results=await Promise.all([s.call('/v1/auth/recover',{data}),s.call('/v1/auth/recover',{data})]);assert.equal(results.filter(r=>r.status===200).length,1);
 let last;for(let i=0;i<22;i++)last=await s.call('/v1/auth/login',{data:{username:'alice',password:'wrong'}});assert.equal(last.status,429);
 }finally{s.close();}
});
