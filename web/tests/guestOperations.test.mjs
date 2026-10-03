import test from 'node:test'
import assert from 'node:assert/strict'
import { GuestOperations, guestEncode } from '../src/lib/guestOperations.ts'

function setup(t, handle) {
  const previous=globalThis.window
  globalThis.window={setTimeout,clearTimeout}
  t.after(()=>{globalThis.window=previous})
  const operations=new GuestOperations()
  const channel={readyState:'open',bufferedAmount:0,send(raw){const message=JSON.parse(raw);const response=handle(message);if(response!==undefined)queueMicrotask(()=>channel.onmessage?.({data:JSON.stringify({id:message.id,result:response})}))}}
  operations.attach(channel);t.after(()=>operations.stop())
  return {operations,channel}
}
test('closing rejects queued work and late replies cannot reach a replacement',async t=>{
  let calls=0
  const {operations,channel}=setup(t,()=>{calls++})
  const first=operations.call('device.info'), second=operations.call('device.info')
  const results=Promise.allSettled([first,second])
  await Promise.resolve();operations.stop()
  channel.onmessage({data:JSON.stringify({id:1,result:{secret:'late'}})})
  assert.deepEqual((await results).map(r=>r.status),['rejected','rejected']);assert.equal(calls,1)
})
test('request queues are bounded under backpressure',async t=>{
  const {operations}=setup(t,()=>undefined)
  const requests=Array.from({length:16},()=>operations.call('device.info'))
  const settled=Promise.allSettled(requests)
  await assert.rejects(operations.call('device.info'),/busy/)
  operations.stop();await settled
})
test('streaming saves verify offsets and abort the writer on a malformed reply',async t=>{
  const calls=[];let aborted=false,closed=false
  const {operations}=setup(t,message=>{calls.push(message.op);return message.op==='transfer.read'?{data:guestEncode(new Uint8Array([1,2])),offset:3}:{ok:true}})
  await assert.rejects(operations.save({transfer:'opaque',size:2,name:'test'},{async write(){assert.fail('Unvalidated bytes were written')},async close(){closed=true},async abort(){aborted=true}}),/Incomplete/)
  assert.ok(aborted&&!closed);assert.deepEqual(calls,['transfer.read','transfer.close'])
})
test('uploads commit only exact bounded chunks; cancellation removes partial work',async t=>{
  const calls=[];const abort=new AbortController()
  const {operations}=setup(t,message=>{calls.push(message);if(message.op==='files.upload.chunk')abort.abort();return {ok:true}})
  const file={size:3,slice(){return new Blob([new Uint8Array([1,2,3])])}}
  await assert.rejects(operations.upload(file,'test',false,abort.signal))
  assert.deepEqual(calls.map(c=>c.op),['files.upload.begin','files.upload.chunk','files.upload.cancel'])
  assert.equal(calls[1].args.offset,0)
})
test('destructive confirmation carries the exact target to its issued token',async t=>{
  const calls=[]
  const {operations}=setup(t,message=>{calls.push(message);return message.op==='confirmation.issue'?{token:'owned-confirmation'}:{ok:true}})
  await operations.confirmed('files.delete',{path:'safe.txt'})
  assert.deepEqual(calls.map(c=>[c.op,c.args]),[['confirmation.issue',{operation:'files.delete',args:{path:'safe.txt'}}],['files.delete',{path:'safe.txt',token:'owned-confirmation'}]])
})
