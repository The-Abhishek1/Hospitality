import {createConnection} from 'node:net';
export const MAX_BYTES=10*1024*1024;
export function ping({host,port=3310,timeout=5000}){
 return new Promise((resolve,reject)=>{
  const socket=createConnection({host,port});let answer='',settled=false;
  const finish=error=>{if(settled)return;settled=true;socket.destroy();error?reject(error):resolve(true);};
  socket.setTimeout(timeout,()=>finish(Error('Scanner unavailable.')));
  socket.on('error',()=>finish(Error('Scanner unavailable.')));
  socket.on('end',()=>finish(Error('Scanner unavailable.')));
  socket.on('connect',()=>socket.write('zPING\0'));
  socket.on('data',chunk=>{answer+=chunk.toString('utf8');if(answer.length>100)return finish(Error('Invalid scanner health reply.'));if(answer.includes('\0'))finish(answer==='PONG\0'?undefined:Error('Scanner unavailable.'));});
 });
}
export function scan(bytes,{host,port=3310,timeout=60000}){
 if(!(bytes instanceof Uint8Array)||!bytes.length||bytes.length>MAX_BYTES)return Promise.reject(Error('Invalid document size.'));
 return new Promise((resolve,reject)=>{
  const socket=createConnection({host,port});let answer='',settled=false;
  const finish=(error,result)=>{if(settled)return;settled=true;socket.destroy();error?reject(error):resolve(result);};
  socket.setTimeout(timeout,()=>finish(Error('Scanner timed out.')));
  socket.on('error',()=>finish(Error('Scanner unavailable.')));
  socket.on('end',()=>{if(!settled)finish(Error('Scanner did not return a complete verdict.'));});
  socket.on('data',chunk=>{
   answer+=chunk.toString('utf8');if(answer.length>4096)return finish(Error('Invalid scanner response.'));
   if(!answer.includes('\0'))return;
   const response=answer.slice(0,answer.indexOf('\0'));
   if(response==='stream: OK')finish(null,'clean');
   else if(/^stream: .+ FOUND$/.test(response))finish(null,'infected');
   else finish(Error('Document could not be verified by the scanner.'));
  });
  socket.on('connect',()=>{
   socket.write('zINSTREAM\0');
   for(let offset=0;offset<bytes.length;offset+=65536){const chunk=bytes.subarray(offset,offset+65536),size=Buffer.alloc(4);size.writeUInt32BE(chunk.length);socket.write(size);socket.write(chunk);}
   socket.write(Buffer.alloc(4));
  });
 });
}
