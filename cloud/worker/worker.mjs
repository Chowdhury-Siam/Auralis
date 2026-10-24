import {TursoStore} from './turso.mjs';
const MAX_BODY = 2 * 1024 * 1024;
export function validate(key, record) {
  let parts;
  try { parts = JSON.parse(key); } catch { throw new Error('Invalid record key'); }
  if (key.length > 600 || !Array.isArray(parts) || parts.length < 2 || parts.length > 3 || parts.some(p => typeof p !== 'string' || !p || p.length > 200) ||
      !record || Object.keys(record).sort().join(',') !== 'clock,device,value' || !Number.isSafeInteger(record.clock) || record.clock < 0 || !/^[a-f0-9]{32}$/.test(record.device) || JSON.stringify(record).length > 16000) throw new Error('Invalid record');
  const v = record.value, integer = n => Number.isSafeInteger(n) && n >= 0;
  switch (parts[0]) {
    case 'favorite': case 'playlist':
      if (parts.length !== 2 || (v !== true && v !== null) || (parts[0] === 'playlist' && parts[1].length > 60)) throw new Error('Invalid collection'); break;
    case 'entry':
      if (parts.length !== 3 || parts[1].length > 60 || (v !== null && (!integer(v) || v > 5000))) throw new Error('Invalid entry'); break;
    case 'recent': if (parts.length !== 2 || (v !== null && !integer(v))) throw new Error('Invalid recent'); break;
    case 'channel': if (parts.length !== 2 || !/^-?\d{1,16}$/.test(parts[1]) || (v !== null && (typeof v !== 'string' || v.length > 1000))) throw new Error('Invalid channel'); break;
    case 'pref':
      if (parts.length !== 2 || !({librarySort:['newest','oldest','title','artist','duration'],repeatMode:['off','all','one']}[parts[1]] ?? []).includes(v)) throw new Error('Invalid preference'); break;
    case 'stats': case 'day':
      if (parts.length !== 3 || (parts[1] !== 'baseline' && !/^[a-f0-9]{32}$/.test(parts[1])) || !v || !integer(v.milliseconds) || !integer(v.plays)) throw new Error('Invalid listening component');
      const fields=parts[0] === 'stats' ? ['title','artist','source','milliseconds','plays','lastListened'] : ['milliseconds','plays'];
      if (Object.keys(v).some(field=>!fields.includes(field))) throw new Error('Unsupported listening field');
      if (parts[0] === 'stats') {
        for (const field of ['title','artist','source']) if (typeof v[field] !== 'string' || v[field].length > 1000) throw new Error('Invalid listening text');
        if (v.lastListened != null && (typeof v.lastListened !== 'string' || v.lastListened.length > 40 || !Number.isFinite(Date.parse(v.lastListened)))) throw new Error('Invalid listening date');
      } else if (!/^\d{4}-\d{2}-\d{2}$/.test(parts[2])) throw new Error('Invalid day');
      break;
    default: throw new Error('Unsupported record');
  }
}
export function merge(key, old, next) {
  validate(key, next);
  if (!old) return next;
  const wins = next.clock > old.clock || (next.clock === old.clock && next.device > old.device);
  let result = wins ? next : old;
  if (['stats','day'].includes(JSON.parse(key)[0])) result = {...result, value:{...result.value,
    milliseconds:Math.max(old.value.milliseconds,next.value.milliseconds), plays:Math.max(old.value.plays,next.value.plays)}};
  return result;
}
const json = (data, status=200) => Response.json(data,{status,headers:{'Cache-Control':'no-store'}});
async function body(request) {
  const reader = request.body?.getReader();
  if (!reader) throw new Error('Missing body');
  const chunks = []; let size=0;
  try {
    for (;;) {
      const {value,done} = await reader.read(); if (done) break;
      size += value.length; if (size > MAX_BODY) throw new Error('Request too large'); chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size); let offset=0;
  for (const c of chunks) { bytes.set(c,offset);offset+=c.length; }
  return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
}
export class AuralisRoom {
  constructor(state,env={}) {
    this.state=state; this.sql=state.storage.sql;
    this.turso=env.TURSO_DATABASE_URL && env.TURSO_AUTH_TOKEN ? new TursoStore(env) : null;
    this.queue=Promise.resolve();this.initialized=false;
    this.sql.exec('CREATE TABLE IF NOT EXISTS records (key TEXT PRIMARY KEY, value TEXT NOT NULL, revision INTEGER NOT NULL)');
    this.sql.exec('CREATE INDEX IF NOT EXISTS revisions ON records(revision)');
    this.sql.exec('CREATE TABLE IF NOT EXISTS meta (id INTEGER PRIMARY KEY, revision INTEGER NOT NULL)');
    this.sql.exec('INSERT OR IGNORE INTO meta VALUES(1,0)');
  }
  async fetch(request) {
    const path=new URL(request.url).pathname;
    if (path === '/v1/live' && request.headers.get('Upgrade')?.toLowerCase() === 'websocket') {
      if (this.state.getWebSockets().length >= 32) return json({error:'Too many devices'},429);
      const pair=new WebSocketPair(); this.state.acceptWebSocket(pair[1]);
      pair[1].send('changed'); return new Response(null,{status:101,webSocket:pair[0]});
    }
    if (path !== '/v1/sync' || request.method !== 'POST') return json({error:'Not found'},404);
    try {
      const data=await body(request);
      if (!Number.isSafeInteger(data.cursor) || data.cursor < 0 || !data.ops || Array.isArray(data.ops) || Object.keys(data.ops).length > 100) throw new Error('Invalid sync request');
      for (const [key,value] of Object.entries(data.ops)) validate(key,value);
      if(this.turso) {
        const task=this.queue.then(async()=>{
          // An older populated DO is never silently replaced by an empty database.
          if(Array.from(this.sql.exec('SELECT count(*) AS n FROM records'))[0].n) throw new Error('Legacy cloud data exists; deploy Turso under a new Worker name');
          if(!this.initialized) {await this.turso.initialize();this.initialized=true;}
          const {changed,output}=await this.turso.sync(data,merge);
          if(changed) this.broadcast();
          return json(output);
        });
        this.queue=task.catch(()=>{});
        try {return await task;} catch {return json({error:'Turso sync is unavailable. Check the deployment and retry; local changes are kept.'},503);}
      }
      let changed=false;
      const output=this.state.storage.transactionSync(() => {
        let revision=Array.from(this.sql.exec('SELECT revision FROM meta WHERE id=1'))[0].revision;
        if (data.cursor > revision) throw new Error('Sync history changed; reconnect to merge this device');
        for (const [key,next] of Object.entries(data.ops)) {
          const raw=Array.from(this.sql.exec('SELECT value FROM records WHERE key=?',key))[0];
          const old=raw ? JSON.parse(raw.value) : null, result=merge(key,old,next);
          if (JSON.stringify(result) !== JSON.stringify(old)) {
            if (!old && Array.from(this.sql.exec('SELECT count(*) AS n FROM records'))[0].n >= 50000) throw new Error('Sync space is full');
            this.sql.exec('INSERT INTO records VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value,revision=excluded.revision', key,JSON.stringify(result),++revision); changed=true;
          }
        }
        this.sql.exec('UPDATE meta SET revision=? WHERE id=1',revision);
        const rows=Array.from(this.sql.exec('SELECT key,value,revision FROM records WHERE revision>? ORDER BY revision LIMIT 200',data.cursor));
        const cursor=rows.length ? rows.at(-1).revision : revision;
        return {cursor,more:cursor<revision,records:Object.fromEntries(rows.map(r => [r.key,JSON.parse(r.value)]))};
      });
      if (changed) this.broadcast();
      return json(output);
    } catch (error) { return json({error:error instanceof Error ? error.message : 'Invalid sync request'},400); }
  }
  broadcast() {for (const ws of this.state.getWebSockets()) {try {ws.send('changed');} catch { /* Polling retries disconnected peers. */ }}}
  webSocketMessage(socket,message) { if (message === 'ping') socket.send('pong'); }
  webSocketClose(socket,code) { socket.close(code,''); }
  webSocketError(socket) { try { socket.close(1011,''); } catch { /* Already closed. */ } }
}
export default {
  async fetch(request,env) {
    const path=new URL(request.url).pathname, configured=/^[a-f0-9]{64}$/.test(env.AURALIS_SYNC_KEY ?? '');
    const turso=Boolean(env.TURSO_DATABASE_URL && env.TURSO_AUTH_TOKEN),partial=Boolean(env.TURSO_DATABASE_URL || env.TURSO_AUTH_TOKEN) && !turso;
    if (path === '/health' && request.method === 'GET') return json({service:'auralis-sync',version:env.AURALIS_VERSION ?? '0.1.68',configured:configured && !partial,backend:turso?'turso':'durable-object'});
    if (!configured) return json({error:'Sync service is not configured'},503);
    const supplied=request.headers.get('Authorization') ?? '';
    const hash=async s => new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s)));
    const a=await hash(supplied),b=await hash(`Bearer ${env.AURALIS_SYNC_KEY}`);
    let difference=0;for(let i=0;i<a.length;i++) difference|=a[i]^b[i];
    if(difference) return json({error:'Invalid sync key'},401);
    if(path==='/v1/info' && request.method==='GET') return json({service:'auralis-sync',version:env.AURALIS_VERSION ?? '0.1.68',backend:turso?'turso':'durable-object'});
    if(partial) return json({error:'Turso configuration is incomplete'},503);
    if(!['/v1/sync','/v1/live'].includes(path)) return json({error:'Not found'},404);
    return env.ROOM.get(env.ROOM.idFromName('private-library')).fetch(request);
  }
};
