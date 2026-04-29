// __claude_wco_shim — marker for patch_wco_shim idempotency check
//
// Window Controls Overlay shim for Linux. Convinces claude.ai's
// React bundle that it's running in a Windows desktop window, so
// the in-app topbar (hamburger / sidebar / search / nav / Cowork
// ghost) renders. claude.ai's bundle gates topbar rendering on a
// `/(win32|win64|windows|wince)/i` test against navigator.userAgent;
// our overrides flip that to true page-side without touching the
// HTTP request UA, plus shim navigator.windowControlsOverlay and
// matchMedia('(display-mode: window-controls-overlay)') as
// defensive forward-compat in case the bundle ever tightens its
// check beyond the UA regex.
//
// Also installs a className intercept that strips 'draggable' from
// any DOM class assignment. This is belt-and-suspenders against
// claude.ai's CSS rule .draggable { app-region: drag } applying
// to in-content elements; in hybrid mode (frame:true) the OS
// handles window dragging via the native titlebar, so any
// remaining app-region:drag inside the BrowserView would only
// produce unexpected click-eaten regions.
//
// Investigation history: docs/learnings/linux-topbar-shim.md.
// CLAUDE_WCO_NATIVE=1 skips all overrides for diagnostic A/B
// testing against unmodified Chromium behavior.
//
// Active only when CLAUDE_TITLEBAR_STYLE != 'native'.

(function() {
	if (process.platform !== 'linux') return;
	var style = (process.env.CLAUDE_TITLEBAR_STYLE || 'hybrid').toLowerCase();
	if (style === 'native') return;

	// Diagnostic mode: skip all overrides so the BrowserView sees
	// Chromium's native behavior. Native-state logging still runs
	// so the user can inspect what Chromium actually reports.
	var nativeMode = process.env.CLAUDE_WCO_NATIVE === '1';

	try {
		var webFrame = require('electron').webFrame;
		if (!webFrame) return;

		// Inline the shim as a string so it runs in the page's main
		// world. CONTROLS_WIDTH leaves room on the right for window
		// controls in the shimmed wco_rect; TITLEBAR_HEIGHT matches
		// the upstream Windows topbar height. nativeMode flag is
		// interpolated so the page script can honor the diagnostic
		// switch.
		var script = [
			'(function(){',
				'if(window.__claudeWcoShimInstalled)return;',
				'window.__claudeWcoShimInstalled=true;',
				'var CONTROLS_WIDTH=140;',
				'var TITLEBAR_HEIGHT=40;',
				'var __nativeMode=' + (nativeMode ? 'true' : 'false') + ';',

				// Diagnostic: capture and log Chromium's NATIVE WCO
				// state. Phase 1 captures non-DOM values synchronously
				// (before any overrides apply). Phase 2 injects a
				// stylesheet to read env(titlebar-area-*) once the DOM
				// is ready, deferred via DOMContentLoaded if necessary
				// — webFrame.executeJavaScript can fire before the html
				// element exists, so an early getComputedStyle call
				// throws "parameter 1 is not of type 'Element'".
				// env() values are CSS-engine state that the shim's
				// overrides don't touch, so reading them late still
				// reflects native behavior. Surfaces in the BrowserView's
				// DevTools console and in the launcher log via the
				// console-message mirror in frame-fix-wrapper.js.
				'var __nativeProbe={};',
				'try{',
					'var __wco=navigator.windowControlsOverlay;',
					'__nativeProbe.visible=!!(__wco&&__wco.visible);',
					'try{',
						'var __r=__wco&&__wco.getTitlebarAreaRect&&__wco.getTitlebarAreaRect();',
						'__nativeProbe.rect=__r?{x:__r.x,y:__r.y,width:__r.width,height:__r.height}:null;',
					'}catch(e){__nativeProbe.rect=null;}',
					'__nativeProbe.media_wco=matchMedia("(display-mode: window-controls-overlay)").matches;',
					'__nativeProbe.media_standalone=matchMedia("(display-mode: standalone)").matches;',
					'__nativeProbe.media_browser=matchMedia("(display-mode: browser)").matches;',
					'__nativeProbe.userAgent=navigator.userAgent;',
					'__nativeProbe.nativeMode=__nativeMode;',
				'}catch(e){__nativeProbe.captureError=e.message;}',

				// Phase 2: inject a stylesheet using CSS env() to extract
				// titlebar-area values, then read them via custom
				// properties. getPropertyValue('env(...)') is invalid;
				// env() is only meaningful inside CSS values, so we
				// indirect through --probe-* custom properties.
				'var __finishProbe=function(){',
					'try{',
						'var __s=document.createElement("style");',
						'__s.textContent=":root{--probe-tbx:env(titlebar-area-x);--probe-tby:env(titlebar-area-y);--probe-tbw:env(titlebar-area-width);--probe-tbh:env(titlebar-area-height);}";',
						'document.head.appendChild(__s);',
						'var __cs=getComputedStyle(document.documentElement);',
						'__nativeProbe.env_x=__cs.getPropertyValue("--probe-tbx").trim();',
						'__nativeProbe.env_y=__cs.getPropertyValue("--probe-tby").trim();',
						'__nativeProbe.env_w=__cs.getPropertyValue("--probe-tbw").trim();',
						'__nativeProbe.env_h=__cs.getPropertyValue("--probe-tbh").trim();',
						'__s.remove();',
					'}catch(e){__nativeProbe.envProbeError=e.message;}',
					'window.__claudeWcoNativeState=__nativeProbe;',
					'console.log("[WCO Diagnostic] BrowserView native state:",JSON.stringify(__nativeProbe));',
				'};',
				'if(document.documentElement&&document.head){',
					'__finishProbe();',
				'}else{',
					'document.addEventListener("DOMContentLoaded",__finishProbe,{once:true});',
				'}',

				// In native diagnostic mode, skip all overrides so
				// the user can see how the page behaves with pure
				// Chromium (and to test whether claude.ai's UA gate
				// passes naturally — it won't, but it lets us
				// confirm that as a baseline). Phase 2 was registered
				// above the early return so it still fires.
				'if(__nativeMode){',
					'console.log("[WCO Shim] CLAUDE_WCO_NATIVE=1, skipping all overrides");',
					'return;',
				'}',

				// 1. Shim navigator.windowControlsOverlay with proper
				//    event-target semantics so React listeners fire.
				'var listeners={};',
				'var overlay={',
					'get visible(){return true},',
					'getTitlebarAreaRect:function(){',
						'return new DOMRect(0,0,Math.max(0,window.innerWidth-CONTROLS_WIDTH),TITLEBAR_HEIGHT);',
					'},',
					'addEventListener:function(t,fn){',
						'(listeners[t]=listeners[t]||[]).push(fn);',
					'},',
					'removeEventListener:function(t,fn){',
						'var arr=listeners[t]||[];',
						'var i=arr.indexOf(fn);',
						'if(i>=0)arr.splice(i,1);',
					'},',
					'dispatchEvent:function(e){',
						'(listeners[e.type]||[]).slice().forEach(function(fn){',
							'try{fn.call(overlay,e)}catch(err){console.warn("[WCO Shim]",err)}',
						'});',
						'if(typeof overlay["on"+e.type]==="function"){',
							'try{overlay["on"+e.type](e)}catch(err){}',
						'}',
						'return true;',
					'},',
					'ongeometrychange:null',
				'};',
				'try{',
					'Object.defineProperty(navigator,"windowControlsOverlay",{',
						'value:overlay,configurable:true',
					'});',
				'}catch(e){console.warn("[WCO Shim] navigator override failed:",e.message)}',

				// 2. Shim matchMedia for the WCO display-mode query.
				//    The CSS @media engine itself can't be fooled, but
				//    JS code that branches on matchMedia().matches can.
				'var origMM=window.matchMedia.bind(window);',
				'window.matchMedia=function(q){',
					'if(typeof q==="string"&&q.indexOf("window-controls-overlay")!==-1){',
						'return{',
							'matches:true,',
							'media:q,',
							'onchange:null,',
							'addEventListener:function(){},',
							'removeEventListener:function(){},',
							'addListener:function(){},',
							'removeListener:function(){},',
							'dispatchEvent:function(){return true}',
						'};',
					'}',
					'return origMM(q);',
				'};',

				// 3. Shim navigator.userAgent so claude.ais isWindows()
				//    check passes. The bundle uses
				//    /(win32|win64|windows|wince)/i.test(navigator.userAgent)
				//    to decide whether to render the desktop topbar
				//    component (data-testid="topbar-windows-menu"). On
				//    Linux the UA contains "X11; Linux x86_64" and the
				//    regex fails, so the topbar is never rendered.
				//    Done page-side only: HTTP request UA is unchanged,
				//    so analytics and anti-bot fingerprints stay honest.
				'try{',
					'var origUA=navigator.userAgent;',
					'if(!/(win32|win64|windows|wince)/i.test(origUA)){',
						'Object.defineProperty(navigator,"userAgent",{',
							'get:function(){return origUA+" Windows"},',
							'configurable:true',
						'});',
					'}',
				'}catch(e){console.warn("[WCO Shim] userAgent override failed:",e.message)}',

				// 4. Strip 'draggable' class from any DOM class
				//    assignment. claude.ai's React renders the topbar
				//    parent with class="draggable absolute top-0
				//    inset-x-0 ..." which triggers a CSS rule
				//    .draggable { -webkit-app-region: drag }. In hybrid
				//    mode (frame:true) the OS handles window dragging,
				//    so any in-content app-region:drag region would
				//    just create surprise click-eaten zones inside the
				//    page. Stripping the class at the JS-DOM API level
				//    means the rule never matches, regardless of how
				//    Chromium decides to consume it.
				//    Three assignment vectors covered:
				//      el.className = '...'
				//      el.setAttribute('class', '...')
				//      el.classList.add('draggable', ...)
				//    Round-trip identity is broken for class strings
				//    containing 'draggable' — el.className=val then
				//    reading el.className will not return val. No
				//    code path in claude.ai's bundle appears to
				//    depend on this; if a regression appears, scope
				//    the strip to the specific class combination
				//    (e.g. /draggable\s+absolute\s+top-0/) instead
				//    of the bare word.
				'try{',
					'var __strip=function(v){',
						'if(typeof v!=="string")return v;',
						'return v.replace(/\\bdraggable\\b/g,"").replace(/\\s+/g," ").trim();',
					'};',
					'var __cnDesc=Object.getOwnPropertyDescriptor(Element.prototype,"className");',
					'if(__cnDesc&&__cnDesc.set){',
						'Object.defineProperty(Element.prototype,"className",{',
							'configurable:true,',
							'enumerable:__cnDesc.enumerable,',
							'get:function(){return __cnDesc.get.call(this)},',
							'set:function(v){__cnDesc.set.call(this,__strip(v))}',
						'});',
					'}',
					'var __origSetAttr=Element.prototype.setAttribute;',
					'Element.prototype.setAttribute=function(n,v){',
						'if((n==="class"||n==="className")&&typeof v==="string"){',
							'v=__strip(v);',
						'}',
						'return __origSetAttr.call(this,n,v);',
					'};',
					'var __origClAdd=DOMTokenList.prototype.add;',
					'DOMTokenList.prototype.add=function(){',
						'var args=[];',
						'for(var i=0;i<arguments.length;i++){',
							'if(arguments[i]!=="draggable")args.push(arguments[i]);',
						'}',
						'return __origClAdd.apply(this,args);',
					'};',
					'console.log("[Drag Shim] className intercept installed");',
				'}catch(e){console.warn("[Drag Shim] className intercept failed:",e.message)}',

				// 5. Fire events to nudge any framework that already
				//    rendered before the shim arrived. geometrychange
				//    is the official WCO signal; resize is a common
				//    fallback React layout effects listen to.
				'setTimeout(function(){',
					'try{overlay.dispatchEvent(new Event("geometrychange"))}catch(e){}',
					'try{window.dispatchEvent(new Event("resize"))}catch(e){}',
				'},0);',



				'console.log("[WCO Shim] Installed in main world");',
			'})();',
		].join('');

		webFrame.executeJavaScript(script).catch(function() {});
	} catch (e) {
		console.warn('[WCO Shim] Preload failed:', e.message);
	}
})();
