const enc=new TextEncoder(),dec=new TextDecoder();
export const json=(v,status=200)=>Response.json(v,{status,headers:{'Cache-Control':'no-store'}});
const random=()=>Array.from(crypto.getRandomValues(new Uint8Array(32)),b=>b.toString(16).padStart(2,'0')).join('');
const secret=env=>env.JWT_SECRET || env.AURALIS_SYNC_KEY;
const b64=v=>btoa(String.fromCharCode(...new Uint8Array(v))).replace(/=/g,'').replace(/\+/g,'-').replace(/\//g,'_');
const un64=v=>Uint8Array.from(atob(v.replace(/-/g,'+').replace(/_/g,'/')),c=>c.charCodeAt(0));
export async function equal(a,b) {const h=s=>crypto.subtle.digest('SHA-256',enc.encode(String(s))),[x,y]=await Promise.all([h(a),h(b)]);const a1=new Uint8Array(x),b1=new Uint8Array(y);let diff=0;for(let i=0;i<a1.length;i++)diff|=a1[i]^b1[i];return diff===0;}
async function digest(v,env) {return b64(await crypto.subtle.digest('SHA-256',enc.encode(`${secret(env)}|${v}`)));}
async function passwordHash(v,salt,env) {
 const key=await crypto.subtle.importKey('raw',enc.encode(`${v}\0${secret(env)}`),'PBKDF2',false,['deriveBits']);
 return b64(await crypto.subtle.deriveBits({name:'PBKDF2',hash:'SHA-256',salt:enc.encode(salt),iterations:100000},key,256));
}
const username=v=>{if(typeof v!=='string'||!/^[a-z0-9][a-z0-9_.-]{2,31}$/.test(v.trim().toLowerCase()))throw Error('Use a username of 3–32 letters, numbers, dots, dashes or underscores');return v.trim().toLowerCase();};
const password=v=>{if(typeof v!=='string'||v.length<10||v.length>128)throw Error('Use a password of 10–128 characters');return v;};
async function signingKey(env) {return crypto.subtle.importKey('raw',enc.encode(secret(env)),{name:'HMAC',hash:'SHA-256'},false,['sign','verify']);}
async function tokenFor(claims,env) {const data=`${b64(enc.encode('{"alg":"HS256","typ":"JWT"}'))}.${b64(enc.encode(JSON.stringify(claims)))}`;return `${data}.${b64(await crypto.subtle.sign('HMAC',await signingKey(env),enc.encode(data)))}`;}
async function claimsFor(token,env) {
 if(typeof token!=='string'||token.length>2000)throw Error('Sign in again');
 const p=token.split('.');if(p.length!==3)throw Error('Sign in again');
 const h=JSON.parse(dec.decode(un64(p[0])));
 if(h.alg!=='HS256'||h.typ!=='JWT'||!await crypto.subtle.verify('HMAC',await signingKey(env),un64(p[2]),enc.encode(`${p[0]}.${p[1]}`)))throw Error('Sign in again');
 const c=JSON.parse(dec.decode(un64(p[1])));if(c.aud!=='auralis-sync'||!Number.isSafeInteger(c.exp)||c.exp<=Date.now()/1000||!/^[a-f0-9]{32}$/.test(c.sub)||!/^[a-f0-9]{64}$/.test(c.jti))throw Error('Sign in again');return c;
}
async function crypt(value,env,decrypt=false) {
 const key=await crypto.subtle.importKey('raw',await crypto.subtle.digest('SHA-256',enc.encode(`${secret(env)}|auralis-owner-recovery`)),'AES-GCM',false,['encrypt','decrypt']);
 const aad=enc.encode('auralis-deployment-v1');
 if(decrypt)return JSON.parse(dec.decode(await crypto.subtle.decrypt({name:'AES-GCM',iv:un64(value.iv),additionalData:aad},key,un64(value.cipher))));
 const iv=crypto.getRandomValues(new Uint8Array(12));return {iv:b64(iv),cipher:b64(await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:aad},key,enc.encode(JSON.stringify(value))))};
}
async function body(request) {
 const reader=request.body?.getReader();if(!reader)throw Error('Missing body');let size=0;const chunks=[];
 try{for(;;){const {done,value}=await reader.read();if(done)break;if((size+=value.length)>16384)throw Error('Request too large');chunks.push(value);}}finally{reader.releaseLock();}
 const bytes=new Uint8Array(size);let i=0;for(const v of chunks){bytes.set(v,i);i+=v.length;}const data=JSON.parse(dec.decode(bytes));if(!data||typeof data!=='object'||Array.isArray(data))throw Error('Invalid request');return data;
}
export class AccountStore {
 constructor(state,env){this.state=state;this.env=env;this.sql=state.storage.sql;
 this.sql.exec('CREATE TABLE IF NOT EXISTS accounts (id TEXT PRIMARY KEY,username TEXT UNIQUE NOT NULL,salt TEXT NOT NULL,password TEXT NOT NULL,recovery TEXT NOT NULL,owner INTEGER NOT NULL,version INTEGER NOT NULL,room TEXT NOT NULL,scope TEXT NOT NULL)');
 this.sql.exec('CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY,account TEXT NOT NULL,expires INTEGER NOT NULL,version INTEGER NOT NULL)');
 this.sql.exec('CREATE TABLE IF NOT EXISTS account_meta (key TEXT PRIMARY KEY,value TEXT NOT NULL)');
 this.sql.exec('CREATE TABLE IF NOT EXISTS auth_limits (key TEXT PRIMARY KEY,window INTEGER NOT NULL,count INTEGER NOT NULL)');}
 first(sql,...args){return Array.from(this.sql.exec(sql,...args))[0];}
 get ownerCreated(){return Boolean(this.first("SELECT value FROM account_meta WHERE key='owner-created'"));}
 rate(request,name){const window=Math.floor(Date.now()/900000);this.sql.exec('DELETE FROM auth_limits WHERE window<?',window-1);
 for(const key of [`ip:${request.headers.get('CF-Connecting-IP')||'unknown'}`,`user:${name}`]){
 const old=this.first('SELECT count FROM auth_limits WHERE key=? AND window=?',key,window);if(old?.count>=20)throw Object.assign(Error('Too many attempts. Try again in 15 minutes'),{status:429});
 this.sql.exec('INSERT INTO auth_limits VALUES(?,?,1) ON CONFLICT(key) DO UPDATE SET window=excluded.window,count=CASE WHEN auth_limits.window=excluded.window THEN auth_limits.count+1 ELSE 1 END',key,window);}}
 public(u){return {id:u.id,username:u.username,admin:Boolean(u.owner),room:u.room,scope:u.scope};}
 async identity(request){const claims=await claimsFor(request.headers.get('Authorization')?.replace(/^Bearer /,''),this.env),u=this.first('SELECT * FROM accounts WHERE id=?',claims.sub),s=this.first('SELECT * FROM sessions WHERE id=?',claims.jti);if(!u||!s||s.account!==u.id||s.version!==u.version||s.expires<=Date.now()/1000)throw Error('Sign in again');return {...u,jti:claims.jti,expires:s.expires};}
 async session(u,code){const now=Math.floor(Date.now()/1000),expires=now+30*86400,jti=random();this.sql.exec('DELETE FROM sessions WHERE expires<=?',now);if(this.first('SELECT count(*) AS n FROM sessions WHERE account=?',u.id).n>=32)throw Error('Sign out of an older device first');this.sql.exec('INSERT INTO sessions VALUES(?,?,?,?)',jti,u.id,expires,u.version);return {user:this.public(u),token:await tokenFor({aud:'auralis-sync',sub:u.id,jti,iat:now,exp:expires},this.env),expires,...(code?{recoveryCode:code}:{})};}
 async revoke(u,jti=''){await this.env.ROOM.get(this.env.ROOM.idFromName(u.room)).fetch(new Request('https://internal/_account/revoke',{method:'POST',headers:{'X-Auralis-Session':jti,'X-Auralis-Scope':u.scope}}));}
 async saveDeployment(data){const keys=['worker','account','cloudflareToken','database','databaseToken','key'];if(keys.some(k=>typeof data[k]!=='string'||!data[k]||data[k].length>4096)||!await equal(data.key,secret(this.env)))throw Error('Deployment credentials must match this Worker');this.sql.exec("INSERT INTO account_meta VALUES('deployment',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",JSON.stringify(await crypt({...Object.fromEntries(keys.map(k=>[k,data[k]])),automatic:data.automatic!==false},this.env)));}
 async dispatch(request){const path=new URL(request.url).pathname;
 if(path==='/_auth/status')return json({ownerCreated:this.ownerCreated});
 if(path==='/_auth/bootstrap'&&request.method==='PUT'){await this.saveDeployment(await body(request));return json({ok:true});}
 if(path==='/v1/auth/register'&&request.method==='POST'){
 const data=await body(request),name=username(data.username),pass=password(data.password);this.rate(request,name);const owner=!this.ownerCreated;
 if(owner&&!await equal(data.claimKey||'',this.env.AURALIS_SYNC_KEY||secret(this.env)))throw Error('Create the owner on the deploying device or enter the existing sync key');
 const id=random().slice(0,32),salt=random(),code=random(),hash=await passwordHash(pass,salt,this.env),recovery=await digest(code,this.env),u={id,username:name,owner:owner?1:0,version:1,room:owner?'private-library':`account-${id}`,scope:owner?'':id};
 this.state.storage.transactionSync(()=>{if(owner&&this.ownerCreated)throw Error('The owner was just created. Retry');if(this.first('SELECT count(*) AS n FROM accounts').n>=100)throw Error('Account limit reached');if(this.first('SELECT id FROM accounts WHERE username=?',name))throw Error('Choose another username');this.sql.exec('INSERT INTO accounts VALUES(?,?,?,?,?,?,?,?,?)',id,name,salt,hash,recovery,u.owner,1,u.room,u.scope);if(owner)this.sql.exec("INSERT INTO account_meta VALUES('owner-created','true')");});
 if(owner)await this.revoke(u);return json(await this.session(u,code));}
 if(path==='/v1/auth/login'&&request.method==='POST'){
 const data=await body(request),name=username(data.username);this.rate(request,name);const u=this.first('SELECT * FROM accounts WHERE username=?',name),hash=await passwordHash(typeof data.password==='string'&&data.password.length<=128?data.password:'',u?.salt||'missing-account-salt',this.env);
 if(!u||!await equal(hash,u.password))return json({error:'Invalid username or password'},401);return json(await this.session(u));}
 if(path==='/v1/auth/recover'&&request.method==='POST'){
 const data=await body(request),name=username(data.username);this.rate(request,name);const u=this.first('SELECT * FROM accounts WHERE username=?',name);
 if(!u||typeof data.recoveryCode!=='string'||!await equal(await digest(data.recoveryCode.trim(),this.env),u.recovery))return json({error:'Invalid username or recovery code'},401);
 const pass=password(data.newPassword),salt=random(),code=random(),hash=await passwordHash(pass,salt,this.env),recovery=await digest(code,this.env);
 this.state.storage.transactionSync(()=>{if(!this.first('UPDATE accounts SET salt=?,password=?,recovery=?,version=version+1 WHERE id=? AND recovery=? RETURNING id',salt,hash,recovery,u.id,u.recovery))throw Error('Recovery code already used');this.sql.exec('DELETE FROM sessions WHERE account=?',u.id);});await this.revoke(u);return json(await this.session(this.first('SELECT * FROM accounts WHERE id=?',u.id),code));}
 let u;try{u=await this.identity(request);}catch{return json({error:'Sign in again'},401);}
 if(path==='/_auth/session')return json({...this.public(u),jti:u.jti,expires:u.expires});
 if(path==='/v1/account'&&request.method==='GET')return json({user:this.public(u)});
 if(path==='/v1/auth/logout'&&request.method==='POST'){this.sql.exec('DELETE FROM sessions WHERE id=?',u.jti);await this.revoke(u,u.jti);return json({ok:true});}
 if(path==='/v1/auth/confirm'&&request.method==='POST'){const data=await body(request);this.rate(request,u.username);if(typeof data.password!=='string'||data.password.length>128||!await equal(await passwordHash(data.password,u.salt,this.env),u.password))return json({error:'Incorrect password'},401);return json(this.public(u));}
 if(path==='/_auth/delete'&&request.method==='DELETE'){this.state.storage.transactionSync(()=>{this.sql.exec('DELETE FROM sessions WHERE account=?',u.id);this.sql.exec('DELETE FROM accounts WHERE id=?',u.id);if(u.owner)this.sql.exec("DELETE FROM account_meta WHERE key='deployment'");});return json({ok:true});}
 if(path==='/v1/account/deployment'&&u.owner){if(request.method==='PUT'){await this.saveDeployment(await body(request));return json({ok:true});}if(request.method==='DELETE'){this.sql.exec("DELETE FROM account_meta WHERE key='deployment'");return json({ok:true});}if(request.method==='GET'){const saved=this.first("SELECT value FROM account_meta WHERE key='deployment'");return json({deployment:saved?await crypt(JSON.parse(saved.value),this.env,true):null,version:this.env.AURALIS_VERSION});}}
 if(path==='/v1/admin/reset'&&request.method==='POST'&&u.owner){const data=await body(request),name=username(data.username),pass=password(data.newPassword);this.rate(request,name);const target=this.first('SELECT * FROM accounts WHERE username=?',name);if(!target||target.id===u.id)throw Error('Use recovery for your own account, or enter another username');const salt=random(),code=random(),hash=await passwordHash(pass,salt,this.env);this.sql.exec('UPDATE accounts SET salt=?,password=?,recovery=?,version=version+1 WHERE id=?',salt,hash,await digest(code,this.env),target.id);this.sql.exec('DELETE FROM sessions WHERE account=?',target.id);await this.revoke(target);return json({ok:true,recoveryCode:code});}
 return json({error:'Not permitted'},403);}
 async fetch(request){try{return await this.dispatch(request);}catch(e){return json({error:e instanceof SyntaxError?'Invalid request':e.message||'Account request failed'},e.status||400);}}
}
export function profilePage(){const nonce=random();return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Auralis recovery</title><style nonce="${nonce}">body{font:16px system-ui;background:#111216;color:#eee;max-width:560px;margin:40px auto;padding:20px}input,button{box-sizing:border-box;width:100%;padding:14px;margin:8px 0;border-radius:14px;border:1px solid #555;background:#24252b;color:inherit}button{background:#c4b5fd;color:#171020}p{white-space:pre-wrap;line-height:1.5}</style><h1>Auralis account recovery</h1><form id="recover"><input name="username" autocomplete="username" placeholder="Username" required><input name="recoveryCode" autocomplete="off" placeholder="Recovery code" required><input name="newPassword" type="password" minlength="10" maxlength="128" autocomplete="new-password" placeholder="New password" required><button>Recover account</button></form><h2>Worker administrator</h2><form id="login"><input name="username" autocomplete="username" placeholder="Owner username" required><input name="password" type="password" autocomplete="current-password" placeholder="Password" required><button>Sign in</button></form><form id="reset" hidden><input name="username" placeholder="Account to reset" required><input name="newPassword" type="password" minlength="10" maxlength="128" placeholder="New password" required><button>Reset account password</button></form><p id="status" role="status"></p><script nonce="${nonce}">let token;const status=document.getElementById('status');for(const id of ['recover','login','reset'])document.getElementById(id).addEventListener('submit',async e=>{e.preventDefault();status.textContent='Working…';try{const r=await fetch('/v1/'+(id==='recover'?'auth/recover':id==='login'?'auth/login':'admin/reset'),{method:'POST',headers:{'Content-Type':'application/json',...(id==='reset'?{Authorization:'Bearer '+token}:{})},body:JSON.stringify(Object.fromEntries(new FormData(e.target)))}),v=await r.json();if(!r.ok)throw Error(v.error);if(id==='login'){if(!v.user.admin)throw Error('Owner sign-in required');token=v.token;document.getElementById('reset').hidden=false;status.textContent='Signed in as owner'}else{status.textContent='Save your new recovery code securely: '+v.recoveryCode;e.target.reset()}}catch(err){status.textContent=err.message}});</script></html>`,{headers:{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store','Content-Security-Policy':`default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'`,'Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff'}});}
