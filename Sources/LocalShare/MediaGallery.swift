import Foundation

// Enhances the same directory rows so search, sorting and folder navigation stay shared.
enum MediaGallery {
    static let css = #"""
    .viewbar,.gallery-actions{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
    .viewbar{margin-top:14px}
    .viewbar button,.gallery-actions button,.gallery-actions a{min-height:38px;padding:0 12px;border:1px solid var(--line);border-radius:10px;background:var(--surface);color:var(--ink);font:600 13px var(--sans);cursor:pointer;text-decoration:none;display:inline-flex;align-items:center;justify-content:center}
    .viewbar .view-toggle{width:38px;padding:0}
    .view-toggle svg{width:16px;height:16px}
    .viewbar button[aria-pressed=true]{background:var(--accentSoft);border-color:var(--accent);color:var(--accent)}
    button:disabled{opacity:.45;cursor:default}
    .thumb{display:none}
    .list.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:12px;background:none;border:0;overflow:visible}
    .grid .row{position:relative;min-width:0;border:1px solid var(--line);border-radius:14px;overflow:hidden;background:var(--surface)}
    .grid .row>a{display:flex;flex-direction:column;align-items:stretch;gap:10px;padding:10px;height:100%}
    .grid .row>a::before,.grid .d-col,.grid .chev{display:none}
    .grid .ic{width:100%;height:auto;aspect-ratio:1;border-radius:8px;font-size:18px}
    .grid .ic svg{width:40px;height:40px}
    .grid .nm{font-size:14px}.grid .sub2{font-size:11px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .grid .thumb{display:block;position:relative;aspect-ratio:1;border-radius:8px;overflow:hidden;background:var(--field)}
    .grid .thumb img{width:100%;height:100%;object-fit:cover;display:block}
    .grid .thumb+.ic{display:none}.grid .thumb.failed{display:none}.grid .thumb.failed+.ic{display:flex}
    .video-badge{position:absolute;bottom:8px;left:8px;background:rgba(0,0,0,.6);color:white;border-radius:999px;width:28px;height:28px;display:grid;place-items:center;font-size:13px}
    .grid .back,.grid .txtentry{grid-column:1/-1}.grid .back>a,.grid .txtentry>a{flex-direction:row;align-items:center}
    .grid .back .ic,.grid .txtentry .ic{width:34px;height:34px;aspect-ratio:auto}
    .gallery{width:min(1100px,calc(100% - 24px));max-width:none;max-height:calc(100dvh - 24px);padding:16px;border:1px solid var(--lineStrong);border-radius:16px;background:var(--surface);color:var(--ink)}
    .gallery::backdrop{background:rgba(0,0,0,.78)}
    .gallery-actions{margin-bottom:12px}.gallery-title{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font:500 14px var(--sans)}
    .gallery-media{display:flex;align-items:center;justify-content:center;min-height:180px}
    .gallery-media img,.gallery-media video{display:block;max-width:100%;max-height:calc(100dvh - 160px);object-fit:contain}
    .gallery-error{color:var(--inkMute);font:14px var(--sans)}
    @media(max-width:560px){.list.grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.gallery{padding:10px}.gallery-actions{gap:6px}.gallery-actions button,.gallery-actions a{padding:0 9px}.gallery-title{flex-basis:100%}}
    """#

    static let script = #"""
    (function(){
      const list=document.querySelector('.list');
      if(!list || !list.querySelector('[data-kind]'))return;
      const rows=Array.from(list.querySelectorAll('[data-kind]'));
      const t=LS_I18N;
      function button(label,parent,cls){const b=document.createElement('button');b.type='button';b.textContent=label;if(cls)b.className=cls;parent.appendChild(b);return b;}
      const bar=document.createElement('div');bar.className='viewbar';
      document.querySelector('.toolbar').after(bar);
      const listButton=button(t.listView,bar),gridButton=button(t.gridView,bar);
      [
        [listButton,'<path d="M2 3h1M6 3h8M2 8h1M6 8h8M2 13h1M6 13h8"/>'],
        [gridButton,'<rect x="2" y="2" width="4" height="4" rx=".7"/><rect x="10" y="2" width="4" height="4" rx=".7"/><rect x="2" y="10" width="4" height="4" rx=".7"/><rect x="10" y="10" width="4" height="4" rx=".7"/>']
      ].forEach(([b,icon])=>{
        b.className='view-toggle';b.title=b.textContent;b.setAttribute('aria-label',b.textContent);
        b.innerHTML='<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'+icon+'</svg>';
      });
      let grid=false;
      const visible=()=>Array.from(list.querySelectorAll('[data-kind]')).filter(r=>r.style.display!=='none');
      const observer=new IntersectionObserver(entries=>entries.forEach(entry=>{
        if(!entry.isIntersecting||!grid)return;
        const media=entry.target;media.src=media.dataset.src;observer.unobserve(media);
      }),{rootMargin:'200px'});
      rows.forEach(r=>{
        const a=r.querySelector('a');
        if(r.dataset.type==='image'||r.dataset.type==='video'){
          const thumb=document.createElement('span');thumb.className='thumb';thumb.setAttribute('aria-hidden','true');
          const media=document.createElement('img');
          const href=a.getAttribute('href');
          media.dataset.src=/\.svg$/i.test(href)?href:'/ls/thumbnail?path='+encodeURIComponent(decodeURIComponent(href));
          media.alt='';media.loading='lazy';media.decoding='async';
          if(r.dataset.type==='video'){const badge=document.createElement('span');badge.className='video-badge';badge.textContent='▶';thumb.appendChild(badge);}
          media.addEventListener('error',()=>thumb.classList.add('failed'));
          thumb.prepend(media);a.prepend(thumb);
        }
        a.addEventListener('click',e=>{
          if(!grid)return;
          if(r.dataset.type==='image'||r.dataset.type==='video'){e.preventDefault();open(r);}
        });
      });
      function setGrid(value){
        grid=value;list.classList.toggle('grid',value);listButton.setAttribute('aria-pressed',String(!value));gridButton.setAttribute('aria-pressed',String(value));
        observer.disconnect();if(value)list.querySelectorAll('[data-src]:not([src])').forEach(m=>observer.observe(m));
        try{sessionStorage.setItem('ls-directory-view',value?'grid':'list');}catch(e){}
      }
      let saved=false;try{saved=sessionStorage.getItem('ls-directory-view')==='grid';}catch(e){}
      setGrid(saved);listButton.onclick=()=>setGrid(false);gridButton.onclick=()=>setGrid(true);
      const dialog=document.createElement('dialog');dialog.className='gallery';dialog.setAttribute('aria-labelledby','gallery-title');
      const actions=document.createElement('div');actions.className='gallery-actions';dialog.appendChild(actions);
      const title=document.createElement('span');title.className='gallery-title';title.id='gallery-title';actions.appendChild(title);
      const prev=button('‹',actions),next=button('›',actions);prev.setAttribute('aria-label',t.previous);next.setAttribute('aria-label',t.next);
      const save=document.createElement('a');save.textContent=t.downloadFile;save.setAttribute('download','');actions.appendChild(save);
      const close=button(t.close,actions);
      const stage=document.createElement('div');stage.className='gallery-media';dialog.appendChild(stage);document.body.appendChild(dialog);
      let current=null,opener=null;
      const mediaRows=()=>visible().filter(r=>r.dataset.type==='image'||r.dataset.type==='video');
      function clearMedia(){const video=stage.querySelector('video');if(video){video.pause();video.removeAttribute('src');video.load();}stage.replaceChildren();}
      function show(r){
        current=r;clearMedia();title.textContent=r.querySelector('.nm').textContent;save.href=r.querySelector('a').href;save.download=title.textContent;
        const media=document.createElement(r.dataset.type==='image'?'img':'video');
        if(media.tagName==='IMG')media.alt=title.textContent;else{media.controls=true;media.playsInline=true;media.preload='metadata';}
        media.onerror=()=>{const error=document.createElement('p');error.className='gallery-error';error.textContent=t.mediaUnavailable;stage.replaceChildren(error);};
        media.src=save.href;stage.appendChild(media);
        const items=mediaRows(),index=items.indexOf(r);prev.disabled=index<=0;next.disabled=index>=items.length-1;
      }
      function open(r){opener=r.querySelector('a');show(r);dialog.showModal();document.body.style.overflow='hidden';history.pushState({lsGallery:true},'');}
      function dismiss(){if(history.state&&history.state.lsGallery)history.back();else cleanup();}
      function cleanup(){dialog.close();clearMedia();document.body.style.overflow='';if(opener)opener.focus();}
      window.addEventListener('popstate',()=>{if(dialog.open)cleanup();});
      close.onclick=dismiss;dialog.addEventListener('cancel',e=>{e.preventDefault();dismiss();});
      dialog.addEventListener('click',e=>{if(e.target===dialog){const rect=dialog.getBoundingClientRect();if(e.clientX<rect.left||e.clientX>rect.right||e.clientY<rect.top||e.clientY>rect.bottom)dismiss();}});
      function move(delta){const items=mediaRows(),r=items[items.indexOf(current)+delta];if(r)show(r);}
      prev.onclick=()=>move(-1);next.onclick=()=>move(1);
      dialog.addEventListener('keydown',e=>{if(e.target.tagName==='VIDEO')return;if(e.key==='ArrowLeft'){e.preventDefault();move(-1);}if(e.key==='ArrowRight'){e.preventDefault();move(1);}});
    })();
    """#
}
