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
 await s.call('/v1/auth/logout',{token:a.token,data:{}});
 const signedIn=(await s.call('/v1/auth/login',{data:{username:'alice',password:'test-password'}})).data;
 assert.deepEqual((await s.call('/v1/account/deployment',{token:signedIn.token})).data.deployment,p);
 assert.equal(s.stores.get('account-registry').db.prepare("SELECT value FROM account_meta WHERE key='deployment'").get().value.includes('cf-secret'),false);
 assert.equal((await s.call('/v1/account/deployment',{method:'DELETE',token:signedIn.token})).status,200);
 assert.equal((await s.call('/v1/account/deployment',{token:signedIn.token})).data.deployment,null);
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
const tgProfile={userId:123456,name:'Telegram user',apiId:12345,apiHash:'f'.repeat(32)};
const tgLink='tg://login?token='+'a'.repeat(43);
test('Telegram linked identity is encrypted, scoped per Auralis account, and unlink cannot be undone by automatic sync',async()=>{
 const s=service();try{const alice=(await register(s)).data,bob=(await register(s,'bob','')).data;
 assert.equal((await s.call('/v1/account/telegram',{token:alice.token,method:'PUT',data:{...tgProfile,databaseKey:'never store this'}})).status,200);
 const row=s.stores.get('account-registry').db.prepare('SELECT value FROM telegram_accounts WHERE account=?').get(alice.user.id).value;
 assert.equal(row.includes(tgProfile.apiHash),false);assert.equal(row.includes('databaseKey'),false);
 assert.deepEqual((await s.call('/v1/account/telegram',{token:alice.token})).data.profile,tgProfile);
 assert.equal((await s.call('/v1/account/telegram',{token:bob.token})).data.profile,null);
 const db=s.stores.get('account-registry').db;db.prepare('INSERT INTO telegram_accounts VALUES(?,?)').run(bob.user.id,row);
 assert.equal((await s.call('/v1/account/telegram',{token:bob.token})).status,400);db.prepare('DELETE FROM telegram_accounts WHERE account=?').run(bob.user.id);
 assert.equal((await s.call('/v1/account/telegram',{token:alice.token,method:'DELETE'})).status,200);
 assert.equal((await s.call('/v1/account/telegram',{token:alice.token,method:'PUT',data:{...tgProfile,automatic:true}})).status,400);
 assert.equal((await s.call('/v1/account/telegram',{token:alice.token})).data.enabled,false);
 assert.equal((await s.call('/v1/account/telegram',{token:alice.token,method:'PUT',data:tgProfile})).status,200);
 }finally{s.close();}
});
test('Telegram device requests require another session and matching code; the token is disclosed once and erased on completion',async()=>{
 const s=service();try{const a=(await register(s)).data,b=(await s.call('/v1/auth/login',{data:{username:'alice',password:'test-password'}})).data;
 await s.call('/v1/account/telegram',{token:a.token,method:'PUT',data:tgProfile});
 const request=(await s.call('/v1/account/telegram/requests',{token:b.token,data:{link:tgLink}})).data;
 const listing=(await s.call('/v1/account/telegram/requests',{token:a.token})).data;assert.equal(listing.requests[0].id,request.id);assert.equal(JSON.stringify(listing).includes(tgLink),false);assert.equal(JSON.stringify(listing).includes(request.code),false);
 const path='/v1/account/telegram/requests/'+request.id;
 assert.equal((await s.call(path+'/claim',{token:b.token,data:{code:request.code}})).status,409);
 assert.equal((await s.call(path+'/claim',{token:a.token,data:{code:request.code==='000000'?'000001':'000000'}})).status,400);
 const claimed=await s.call(path+'/claim',{token:a.token,data:{code:request.code}});assert.equal(claimed.data.link,tgLink);assert.equal(claimed.data.userId,tgProfile.userId);
 assert.equal((await s.call(path+'/claim',{token:a.token,data:{code:request.code}})).status,409);
 assert.equal((await s.call(path+'/complete',{token:b.token,data:{ok:true}})).status,403);
 assert.equal((await s.call(path+'/complete',{token:a.token,data:{ok:true}})).status,200);
 assert.equal((await s.call(path,{token:b.token})).data.state,'approved');
 assert.equal(s.stores.get('account-registry').db.prepare('SELECT value FROM telegram_links WHERE id=?').get(request.id).value,'');
 }finally{s.close();}
});
test('Telegram requests reject foreign accounts, malformed tokens, expiry and logout',async()=>{
 const s=service();try{const a=(await register(s)).data,requester=(await s.call('/v1/auth/login',{data:{username:'alice',password:'test-password'}})).data,b=(await register(s,'bob','')).data;
 await s.call('/v1/account/telegram',{token:a.token,method:'PUT',data:tgProfile});await s.call('/v1/account/telegram',{token:b.token,method:'PUT',data:tgProfile});
 for(const link of ['https://evil.example/token','tg://login?token=short',tgLink+'&x=y'])assert.equal((await s.call('/v1/account/telegram/requests',{token:requester.token,data:{link}})).status,400);
 const r=(await s.call('/v1/account/telegram/requests',{token:requester.token,data:{link:tgLink}})).data,path='/v1/account/telegram/requests/'+r.id;
 assert.equal((await s.call(path+'/claim',{token:b.token,data:{code:r.code}})).status,404);
 s.stores.get('account-registry').db.prepare('UPDATE telegram_links SET expires=0 WHERE id=?').run(r.id);
 assert.equal((await s.call(path+'/claim',{token:a.token,data:{code:r.code}})).status,404);
 const next=(await s.call('/v1/account/telegram/requests',{token:requester.token,data:{link:tgLink}})).data;
 await s.call('/v1/auth/logout',{token:requester.token,data:{}});
 assert.equal((await s.call('/v1/account/telegram/requests/'+next.id+'/claim',{token:a.token,data:{code:next.code}})).status,404);
 }finally{s.close();}
});
test('Auralis deletion removes its encrypted Telegram link and pending requests',async()=>{
 const s=service();try{const a=(await register(s)).data,b=(await s.call('/v1/auth/login',{data:{username:'alice',password:'test-password'}})).data;
 await s.call('/v1/account/telegram',{token:a.token,method:'PUT',data:tgProfile});await s.call('/v1/account/telegram/requests',{token:b.token,data:{link:tgLink}});
 assert.equal((await s.call('/v1/account',{token:a.token,method:'DELETE',data:{password:'test-password'}})).status,200);
 const db=s.stores.get('account-registry').db;assert.equal(db.prepare('SELECT count(*) AS n FROM telegram_accounts').get().n,0);assert.equal(db.prepare('SELECT count(*) AS n FROM telegram_links').get().n,0);
 }finally{s.close();}
});

test('only one approving session can claim a Telegram login token concurrently',async()=>{
 const s=service();try{const a=(await register(s)).data,b=(await s.call('/v1/auth/login',{data:{username:'alice',password:'test-password'}})).data,c=(await s.call('/v1/auth/login',{data:{username:'alice',password:'test-password'}})).data;
 await s.call('/v1/account/telegram',{token:a.token,method:'PUT',data:tgProfile});const r=(await s.call('/v1/account/telegram/requests',{token:b.token,data:{link:tgLink}})).data;
 const results=await Promise.all([a,c].map(u=>s.call('/v1/account/telegram/requests/'+r.id+'/claim',{token:u.token,data:{code:r.code}})));
 assert.equal(results.filter(r=>r.status===200).length,1);assert.equal(results.filter(r=>r.status===409).length,1);
 }finally{s.close();}
});
