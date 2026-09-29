import JSZip from "jszip";
// Public presentation export, deliberately separate from the private signed package.
export function previewDescriptor(name, clip) {
 if(!/^[a-z][a-z0-9_]{0,47}$/.test(name)||!Array.isArray(clip.frames)||!clip.frames.length||clip.frames.length>256||!Number.isFinite(clip.targetFps)||clip.targetFps<1||clip.targetFps>120)throw new Error("Invalid preview clip: "+name);
 return {name,sheet:name+".webp",thumbnail:name+".png",columns:Math.min(16,clip.frames.length),rows:Math.ceil(clip.frames.length/16),frameCount:clip.frames.length,frameWidth:192,frameHeight:192,fps:clip.targetFps,loop:Boolean(clip.loop)};
}
function blobFromCanvas(canvas,type){return new Promise((resolve,reject)=>canvas.toBlob(blob=>blob?resolve(blob):reject(new Error("Preview image encoding failed")),type,0.8));}
function imageFromFrame(frame){return new Promise((resolve,reject)=>{const image=new Image();image.onload=()=>resolve(image);image.onerror=()=>reject(new Error("Preview frame could not load"));image.src=frame;});}
export async function exportStorePreview(clips,project){
 if(!/^[a-z0-9]+(?:[.-][a-z0-9]+)*$/.test(project.id)||!/^\d+\.\d+\.\d+(?:-[\w.-]+)?(?:\+[\w.-]+)?$/.test(project.version))throw new Error("Set a valid package ID and version first");
 const entries=Object.entries(clips).filter(([,clip])=>clip.frames?.length);
 if(!entries.length||entries.length>64)throw new Error("Sample animation frames before exporting a preview");
 const zip=new JSZip(),folder=zip.folder("previews/"+project.id+"/"+project.version),animations=[];
 for(const [name,clip] of entries){
  const descriptor=previewDescriptor(name,clip);
  const canvas=document.createElement("canvas");canvas.width=descriptor.columns*192;canvas.height=descriptor.rows*192;
  const context=canvas.getContext("2d");
  const thumb=document.createElement("canvas");thumb.width=192;thumb.height=192;
  for(let i=0;i<clip.frames.length;i++){
   const image=await imageFromFrame(clip.frames[i]);
   context.drawImage(image,(i%descriptor.columns)*192,Math.floor(i/descriptor.columns)*192,192,192);
   if(i===0)thumb.getContext("2d").drawImage(image,0,0,192,192);
  }
  const sheet=await blobFromCanvas(canvas,"image/webp");
  if(sheet.type!=="image/webp")descriptor.sheet=name+".png";
  folder.file(descriptor.sheet,sheet);
  folder.file(descriptor.thumbnail,await blobFromCanvas(thumb,"image/png"));
  animations.push(descriptor);
 }
 const descriptions=Object.fromEntries([["en",String(project.descriptionEn??"").trim()],["th",String(project.descriptionTh??"").trim()]].filter(([,value])=>value));
 folder.file("manifest.json",JSON.stringify({schemaVersion:1,characterId:project.id,version:project.version,name:project.name,publisher:project.author||"ocp.local",license:project.license,descriptions,animations},null,2));
 zip.file("README.txt","PUBLIC PREVIEW MEDIA — no private .ocp or credentials included.\nExtract the previews directory into apps/store-web/public after reviewing the images and rights to publish. Build/deploy Store to publish. Exact character ID and version must match the catalog. Public previews can be copied. Audio is omitted.\n");
 const blob=await zip.generateAsync({type:"blob"}),url=URL.createObjectURL(blob),a=document.createElement("a");
 a.href=url;a.download=project.id+"-"+project.version+"-store-preview.zip";a.click();setTimeout(()=>URL.revokeObjectURL(url),30000);
 return animations.length;
}
