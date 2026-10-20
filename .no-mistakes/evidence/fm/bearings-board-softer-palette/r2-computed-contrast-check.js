() => {
 const canvas=document.createElement('canvas');canvas.width=canvas.height=1; const ctx=canvas.getContext('2d',{willReadFrequently:true});
 const rgba=color=>{ctx.clearRect(0,0,1,1);ctx.fillStyle=color;ctx.fillRect(0,0,1,1);const a=[...ctx.getImageData(0,0,1,1).data];a[3]/=255;return a;};
 const over=(f,b)=>{const a=f[3]+b[3]*(1-f[3]);return [0,1,2].map(i=>(f[i]*f[3]+b[i]*b[3]*(1-f[3]))/a).concat(a);};
 const bg=e=>e?over(rgba(getComputedStyle(e).backgroundColor),bg(e.parentElement)):[255,255,255,1];
 const lum=c=>c.slice(0,3).map(v=>{v/=255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4;}).reduce((a,v,i)=>a+v*[.2126,.7152,.0722][i],0);
 const rows=[];const visible=e=>e.checkVisibility({checkVisibilityCSS:true,checkOpacity:true})&&e.getBoundingClientRect().width>0;
 for(const e of document.body.querySelectorAll('*')){
  if(!visible(e)||e.closest('svg,script,style,button:disabled'))continue;
  const text=[...e.childNodes].filter(n=>n.nodeType===3).map(n=>n.textContent.trim()).join(' ').trim();
  if(!text)continue;const s=getComputedStyle(e),b=bg(e),f=over(rgba(s.color),b),l1=lum(f),l2=lum(b),ratio=(Math.max(l1,l2)+.05)/(Math.min(l1,l2)+.05);
  const threshold=parseFloat(s.fontSize)>=24||(parseFloat(s.fontSize)>=18.66&&parseInt(s.fontWeight)>=700)?3:4.5;
  rows.push({text,foreground:s.color,background:b.slice(0,3).map(Math.round),ratio:+ratio.toFixed(2),threshold,pass:ratio>=threshold});
 }
 const input=document.querySelector('.bb-freeform'), ps=getComputedStyle(input,'::placeholder'),b=bg(input),f=over(rgba(ps.color),b),ratio=(Math.max(lum(f),lum(b))+.05)/(Math.min(lum(f),lum(b))+.05);
 const p={text:input.placeholder,foreground:ps.color,background:b,opacity:ps.opacity,ratio:+ratio.toFixed(2),pass:ratio>=4.5};
 return {bodyBackground:getComputedStyle(document.body).backgroundColor,colorScheme:getComputedStyle(document.documentElement).colorScheme,browserPrefersLight:matchMedia('(prefers-color-scheme: light)').matches,viewport:innerWidth,scrollWidth:document.documentElement.scrollWidth,placeholder:p,minimumTextContrast:Math.min(...rows.map(r=>r.ratio)),failures:rows.filter(r=>!r.pass),rows};
}
