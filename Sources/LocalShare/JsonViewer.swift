import Foundation

// JSON 预览（PreviewPage 壳 + 手写折叠树，零 vendored 依赖）。fetch 同 URL 的 ?raw=1 →
// JSON.parse → 树视图：对象/数组用原生 <details> 折叠（前两层默认展开），子节点首次展开才
// 构建（懒渲染），超长数组/对象按 500 一档「再显示」——大文件不炸 DOM。搜索走数据而非 DOM：
// 全量遍历键与原始值，命中以「完整路径 + 值」平铺列出（上限 500），清空即回树。
// 长字符串截断 200 字符、点击展开全文。解析失败给「查看原文」出口。
enum JsonViewer {
    static func html(fileName: String, crumbs: String?, canUpload: Bool, lang: Lang) -> String {
        PreviewPage.html(
            fileName: fileName, crumbs: crumbs, canUpload: canUpload, lang: lang,
            body: """
            <div class="card">
              <div class="vbar">
                <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="7" cy="7" r="4.3"/><path d="M10.3 10.3L14 14"/></svg>
                <input id="q" placeholder="\(L.webSearchJSON(lang))" autocomplete="off" autocapitalize="off" spellcheck="false">
                <span class="vmeta" id="meta"></span>
              </div>
              <div class="vbody" id="view"><p class="ld">\(L.webLoading(lang))</p></div>
            </div>
            """,
            css: css, scripts: [boot])
    }

    private static let css = """
        .vbar{display:flex;align-items:center;gap:9px;padding:11px 16px;border-bottom:1px solid var(--line)}
        .vbar svg{flex:none;color:var(--inkMute)}
        .vbar input{flex:1;min-width:0;border:none;background:transparent;outline:none;
          font:13.5px var(--mono);color:var(--ink)}
        .vmeta{flex:none;font:11.5px var(--mono);color:var(--inkFaint);white-space:nowrap}
        .vbody{padding:12px 16px;overflow-x:auto}
        .tree{font:12.5px/1.9 var(--mono)}
        .tree summary{cursor:pointer;list-style:none;white-space:nowrap;border-radius:6px}
        .tree summary::-webkit-details-marker{display:none}
        .tree summary::before{content:"▸";display:inline-block;width:14px;color:var(--inkFaint);
          transition:transform .12s}
        .tree details[open]>summary::before{transform:rotate(90deg)}
        .tree summary:hover{background:var(--surfaceAlt)}
        .tree .kids{margin-left:6px;border-left:1px solid var(--line);padding-left:14px}
        .ln{padding-left:14px}
        .ln .v{word-break:break-all}
        .k{color:var(--ink)}
        .k::after{content:": ";color:var(--inkFaint)}
        .badge{font-size:10.5px;color:var(--inkFaint);margin-left:5px}
        .t-str{color:var(--ok)}
        .t-num{color:var(--accent)}
        .t-bool{color:var(--warn)}
        .t-null{color:var(--inkMute);font-style:italic}
        .v.cut{cursor:pointer}
        .v.full{white-space:pre-wrap;word-break:break-all}
        .more{display:block;margin:5px 0 5px 14px;padding:4px 12px;border-radius:999px;cursor:pointer;
          font:600 11.5px var(--sans);border:1px solid var(--line);background:transparent;color:var(--inkMute)}
        .more:hover{border-color:var(--lineStrong);color:var(--ink)}
        .mrow{padding:7px 2px;border-bottom:1px dashed var(--line);font:12px/1.7 var(--mono)}
        .mrow:last-child{border-bottom:none}
        .mpath{color:var(--inkMute);margin-right:10px;word-break:break-all}
        .nores{padding:34px;text-align:center;font:13.5px var(--sans);color:var(--inkMute)}
        @media(max-width:560px){
          .vbody{padding:10px 12px}
        }
        """

    private static let boot = """
        (function(){
          var view=document.getElementById('view'),meta=document.getElementById('meta'),q=document.getElementById('q');
          var DATA,SIZE=0,CHUNK=500,CUT=200,MAXHIT=500;

          function fmtSize(n){return n<1024?n+' B':n<1048576?(n/1024).toFixed(1)+' KB':(n/1048576).toFixed(1)+' MB'}
          function isObj(v){return v!==null&&typeof v==='object'}
          function badge(v){return Array.isArray(v)?'['+v.length+']':'{'+Object.keys(v).length+'}'}
          function kindLabel(v){
            if(Array.isArray(v))return LS_I18N.jsonArray.replace('{n}',v.length);
            if(isObj(v))return LS_I18N.jsonObject.replace('{n}',Object.keys(v).length);
            return typeof v==='string'?LS_I18N.typeString:v===null?'null':typeof v==='number'?LS_I18N.typeNumber:LS_I18N.typeBool;
          }
          function baseMeta(){meta.textContent=kindLabel(DATA)+' · '+fmtSize(SIZE)}
          function fail(){view.innerHTML='<p class="ld">'+LS_I18N.parseFailed+' · <a href="?raw=1">'+LS_I18N.viewRaw+'</a></p>'}

          function keySpan(k){var s=document.createElement('span');s.className='k';s.textContent=k;return s}
          function valueSpan(v){
            var s=document.createElement('span');
            if(typeof v==='string'){
              s.className='v t-str';
              if(v.length>CUT){
                var brief=JSON.stringify(v.slice(0,CUT))+LS_I18N.jsonChars.replace('{n}',v.length);
                s.classList.add('cut');s.textContent=brief;s.title=LS_I18N.expandFull;
                s.onclick=function(){
                  var full=s.classList.toggle('full');
                  s.textContent=full?JSON.stringify(v):brief;
                };
              }else s.textContent=JSON.stringify(v);
            }else if(typeof v==='number'){s.className='v t-num';s.textContent=String(v)}
            else if(typeof v==='boolean'){s.className='v t-bool';s.textContent=String(v)}
            else{s.className='v t-null';s.textContent='null'}
            return s;
          }
          function entryNode(k,v,depth){
            if(!isObj(v)){
              var d=document.createElement('div');d.className='ln';
              if(k!==null)d.appendChild(keySpan(k));
              d.appendChild(valueSpan(v));
              return d;
            }
            var det=document.createElement('details');
            if(depth<2)det.open=true;
            var sum=document.createElement('summary');
            if(k!==null)sum.appendChild(keySpan(k));
            var b=document.createElement('span');b.className='badge';b.textContent=badge(v);
            sum.appendChild(b);det.appendChild(sum);
            var kids=document.createElement('div');kids.className='kids';det.appendChild(kids);
            var built=false;
            function build(){if(built)return;built=true;fill(kids,v,0,depth)}
            if(det.open)build();
            else det.addEventListener('toggle',function(){if(det.open)build()});
            return det;
          }
          function fill(box,v,from,depth){
            var keys=Array.isArray(v)?null:Object.keys(v);
            var len=keys?keys.length:v.length;
            var to=Math.min(from+CHUNK,len);
            for(var i=from;i<to;i++){
              var k=keys?keys[i]:i;
              box.appendChild(entryNode(String(k),keys?v[keys[i]]:v[i],depth+1));
            }
            if(to<len){
              var m=document.createElement('button');m.className='more';
              m.textContent=LS_I18N.moreItems.replace('{n}',Math.min(CHUNK,len-to)).replace('{r}',len-to);
              m.onclick=function(){m.remove();fill(box,v,to,depth)};
              box.appendChild(m);
            }
          }
          function showTree(){
            baseMeta();
            var t=document.createElement('div');t.className='tree';
            t.appendChild(entryNode(null,DATA,0));
            view.innerHTML='';view.appendChild(t);
          }

          // 搜索：遍历数据收集 {路径, 值}，对象键名或原始值包含关键词即命中（不区分大小写）。
          function doSearch(){
            var s=q.value.trim().toLowerCase();
            if(DATA===undefined)return;
            if(!s){showTree();return}
            var hits=[];
            (function walk(v,path){
              if(hits.length>=MAXHIT)return;
              if(!isObj(v)){
                if(String(v).toLowerCase().indexOf(s)>=0)hits.push({p:path||'$',v:v});
                return;
              }
              var arr=Array.isArray(v),keys=arr?null:Object.keys(v),len=arr?v.length:keys.length;
              for(var i=0;i<len&&hits.length<MAXHIT;i++){
                var k=arr?i:keys[i],c=arr?v[i]:v[k];
                var p=arr?path+'['+k+']':(path?path+'.':'')+k;
                if(!arr&&String(k).toLowerCase().indexOf(s)>=0)hits.push({p:p,v:c});
                else if(!isObj(c)&&String(c).toLowerCase().indexOf(s)>=0)hits.push({p:p,v:c});
                if(isObj(c))walk(c,p);
              }
            })(DATA,'');
            meta.textContent=LS_I18N.jsonMatches.replace('{n}',hits.length>=MAXHIT?MAXHIT+'+':hits.length);
            var box=document.createElement('div');
            if(!hits.length)box.innerHTML='<div class="nores">'+LS_I18N.noMatch+'</div>';
            else hits.forEach(function(h){
              var r=document.createElement('div');r.className='mrow';
              var p=document.createElement('span');p.className='mpath';p.textContent=h.p;
              r.appendChild(p);
              if(isObj(h.v)){var b=document.createElement('span');b.className='badge';b.textContent=badge(h.v);r.appendChild(b)}
              else r.appendChild(valueSpan(h.v));
              box.appendChild(r);
            });
            view.innerHTML='';view.appendChild(box);
          }
          var deb;
          q.addEventListener('input',function(){clearTimeout(deb);deb=setTimeout(doSearch,160)});

          fetch(location.pathname+'?raw=1',{cache:'no-store'}).then(function(r){
            if(!r.ok)throw 0;
            SIZE=+r.headers.get('content-length')||0;
            return r.text();
          }).then(function(t){
            SIZE=SIZE||t.length;
            DATA=JSON.parse(t);
            showTree();
          }).catch(fail);
        })();
        """
}
