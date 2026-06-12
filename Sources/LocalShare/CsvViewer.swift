import Foundation

// CSV/TSV 预览（PreviewPage 壳 + 手写解析渲染，零 vendored 依赖）。fetch ?raw=1 → RFC4180
// 状态机解析（引号字段、转义引号、字段内换行），分隔符在 , ; \\t 间按首行频次自动判定；
// 首行恒作表头。点击表头排序（采样判定数值列走数值比较）、输入框按任意单元格筛选行；
// 排序/筛选作用于全量数据，DOM 按 1000 行一档「再显示」渐进渲染——几十 MB 不卡死页面。
enum CsvViewer {
    static func html(fileName: String, crumbs: String?, canUpload: Bool) -> String {
        PreviewPage.html(
            fileName: fileName, crumbs: crumbs, canUpload: canUpload,
            body: """
            <div class="card">
              <div class="vbar">
                <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="7" cy="7" r="4.3"/><path d="M10.3 10.3L14 14"/></svg>
                <input id="q" placeholder="筛选行…" autocomplete="off" autocapitalize="off" spellcheck="false">
                <span class="vmeta" id="meta"></span>
              </div>
              <div class="vbody" id="view"><p class="ld">正在加载…</p></div>
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
        .vbody{overflow-x:auto}
        .vbody>.ld{padding:12px 16px}
        table.cv{border-collapse:collapse;width:100%;font:12.5px var(--mono)}
        .cv th{position:sticky;top:0;z-index:1;background:var(--surfaceAlt);
          font:600 12px var(--sans);color:var(--ink);text-align:left;padding:9px 14px;
          border-bottom:1px solid var(--lineStrong);cursor:pointer;white-space:nowrap;
          -webkit-user-select:none;user-select:none}
        .cv th:hover{color:var(--accent)}
        .cv th .arr{margin-left:5px;font-size:9.5px;color:var(--accent)}
        .cv td{padding:7px 14px;border-bottom:1px solid var(--line);white-space:nowrap;
          max-width:420px;overflow:hidden;text-overflow:ellipsis}
        .cv tbody tr:hover td{background:var(--surfaceAlt)}
        .cv tbody tr:last-child td{border-bottom:none}
        .morewrap{padding:10px 14px}
        .more{display:block;width:100%;padding:7px 0;border-radius:10px;cursor:pointer;
          font:600 12px var(--sans);border:1px solid var(--line);background:transparent;color:var(--inkMute)}
        .more:hover{border-color:var(--lineStrong);color:var(--ink)}
        .nores{padding:34px;text-align:center;font:13.5px var(--sans);color:var(--inkMute)}
        @media(max-width:560px){
          .cv td{max-width:230px}
        }
        """

    private static let boot = """
        (function(){
          var view=document.getElementById('view'),meta=document.getElementById('meta'),q=document.getElementById('q');
          var HEADER=[],ROWS=[],SHOWN=[],SIZE=0,CHUNK=1000;
          var sortCol=-1,sortAsc=true,numericCol=[];

          function fmtSize(n){return n<1024?n+' B':n<1048576?(n/1024).toFixed(1)+' KB':(n/1048576).toFixed(1)+' MB'}
          function esc(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')}
          function fail(){view.innerHTML='<p class="ld">解析失败 · <a href="?raw=1">查看原文</a></p>'}

          // RFC4180：引号字段、"" 转义、字段内换行；\\r 忽略。
          function parse(text,sep){
            var rows=[],row=[],cur='',inQ=false;
            for(var i=0;i<text.length;i++){
              var c=text[i];
              if(inQ){
                if(c==='"'){if(text[i+1]==='"'){cur+='"';i++}else inQ=false}
                else cur+=c;
              }
              else if(c==='"')inQ=true;
              else if(c===sep){row.push(cur);cur=''}
              else if(c==='\\n'){row.push(cur);rows.push(row);row=[];cur=''}
              else if(c!=='\\r')cur+=c;
            }
            if(cur!==''||row.length){row.push(cur);rows.push(row)}
            // 去掉末尾空行
            while(rows.length&&rows[rows.length-1].length===1&&rows[rows.length-1][0]==='')rows.pop();
            return rows;
          }
          function detectSep(t){
            var head=(t.slice(0,2048).split('\\n')[0]||'');
            var best=',',n=-1;
            [',',';','\\t'].forEach(function(s){var c=head.split(s).length-1;if(c>n){n=c;best=s}});
            return best;
          }
          // 数值列判定：采样前 200 个非空值，≥90% 可解析为有限数则按数值排序。
          function detectNumeric(){
            numericCol=HEADER.map(function(_,c){
              var seen=0,num=0;
              for(var r=0;r<ROWS.length&&seen<200;r++){
                var cell=ROWS[r][c];
                if(cell==null||cell==='')continue;
                seen++;
                if(isFinite(parseFloat(cell))&&/^[-+0-9.eE,%\\s]+$/.test(cell))num++;
              }
              return seen>0&&num/seen>=0.9;
            });
          }
          function cellNum(s){return parseFloat(String(s).replace(/[,%\\s]/g,''))}

          function applyView(){
            var s=q.value.trim().toLowerCase();
            SHOWN=!s?ROWS.slice():ROWS.filter(function(r){
              for(var i=0;i<r.length;i++)if(r[i].toLowerCase().indexOf(s)>=0)return true;
              return false;
            });
            if(sortCol>=0){
              var dir=sortAsc?1:-1,numeric=numericCol[sortCol];
              SHOWN.sort(function(a,b){
                var x=a[sortCol]||'',y=b[sortCol]||'';
                if(numeric){var nx=cellNum(x),ny=cellNum(y);
                  if(isNaN(nx))return 1;if(isNaN(ny))return -1;return (nx-ny)*dir}
                return x.localeCompare(y,'zh')*dir;
              });
            }
            meta.textContent=(s?SHOWN.length+' / ':'')+ROWS.length+' 行 × '+HEADER.length+' 列 · '+fmtSize(SIZE);
            renderTable();
          }
          function headHTML(){
            var h='<tr>';
            HEADER.forEach(function(c,i){
              h+='<th data-c="'+i+'">'+esc(c||'·');
              if(i===sortCol)h+='<span class="arr">'+(sortAsc?'▲':'▼')+'</span>';
              h+='</th>';
            });
            return h+'</tr>';
          }
          function rowsHTML(from,to){
            var h='';
            for(var r=from;r<to;r++){
              h+='<tr>';
              for(var c=0;c<HEADER.length;c++){
                var cell=SHOWN[r][c]||'';
                h+='<td'+(cell.length>60?' title="'+esc(cell)+'"':'')+'>'+esc(cell)+'</td>';
              }
              h+='</tr>';
            }
            return h;
          }
          function renderTable(){
            if(!SHOWN.length){
              view.innerHTML='<div class="nores">'+(ROWS.length?'未找到匹配的行':'这个文件没有数据行')+'</div>';
              return;
            }
            var to=Math.min(CHUNK,SHOWN.length);
            view.innerHTML='<table class="cv"><thead>'+headHTML()+'</thead><tbody>'+rowsHTML(0,to)+'</tbody></table>'
              +(to<SHOWN.length?'<div class="morewrap"><button class="more">再显示 '+Math.min(CHUNK,SHOWN.length-to)+' 行（剩 '+(SHOWN.length-to)+'）</button></div>':'');
            var shownTo=to;
            var moreBtn=view.querySelector('.more');
            if(moreBtn)moreBtn.onclick=function(){
              var next=Math.min(shownTo+CHUNK,SHOWN.length);
              view.querySelector('tbody').insertAdjacentHTML('beforeend',rowsHTML(shownTo,next));
              shownTo=next;
              if(next>=SHOWN.length)moreBtn.parentNode.remove();
              else moreBtn.textContent='再显示 '+Math.min(CHUNK,SHOWN.length-next)+' 行（剩 '+(SHOWN.length-next)+'）';
            };
            view.querySelectorAll('th').forEach(function(th){
              th.onclick=function(){
                var c=+th.getAttribute('data-c');
                if(sortCol===c)sortAsc=!sortAsc;else{sortCol=c;sortAsc=true}
                applyView();
              };
            });
          }

          var deb;
          q.addEventListener('input',function(){clearTimeout(deb);deb=setTimeout(applyView,160)});

          fetch(location.pathname+'?raw=1',{cache:'no-store'}).then(function(r){
            if(!r.ok)throw 0;
            SIZE=+r.headers.get('content-length')||0;
            return r.text();
          }).then(function(t){
            SIZE=SIZE||t.length;
            view.innerHTML='<p class="ld">正在解析…</p>';
            setTimeout(function(){
              try{
                var sep=/\\.tsv(\\?|$)/i.test(location.pathname)?'\\t':detectSep(t);
                var rows=parse(t,sep);
                if(!rows.length){view.innerHTML='<div class="nores">这个文件是空的</div>';meta.textContent='0 行';return}
                HEADER=rows[0];ROWS=rows.slice(1);
                detectNumeric();
                applyView();
              }catch(e){fail()}
            },10);
          }).catch(fail);
        })();
        """
}
