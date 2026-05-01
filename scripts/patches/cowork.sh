#===============================================================================
# Cowork-mode Linux patches (TypeScript VM client, Unix socket, daemon
# auto-launch, smol-bin copy, sharedCwdPath forwarding, etc.) and node-pty
# installation/staging for terminal support.
#
# Sourced by: build.sh
# Sourced globals:
#   node_pty_dir, work_dir, app_staging_dir
# Modifies globals: node_pty_build_dir
#===============================================================================

patch_cowork_linux() {
	echo 'Patching Cowork mode for Linux...'
	local index_js='app.asar.contents/.vite/build/index.js'

	if ! grep -q 'vmClient (TypeScript)' "$index_js"; then
		echo '  Cowork mode code not found in this version, skipping'
		echo '##############################################################'
		return
	fi

	# All complex patches are done via node to avoid shell escaping issues
	# with minified JavaScript. Uses unique string anchors and dynamic
	# variable extraction to be version-agnostic per CLAUDE.md guidelines.
	if ! INDEX_JS="$index_js" SVC_PATH="cowork-vm-service.js" \
		node << 'COWORK_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
let code = fs.readFileSync(indexJs, 'utf8');
let patchCount = 0;

// Helper: extract a balanced block starting at a delimiter.
// Returns the substring from open to close (inclusive), or null.
// Works for {} [] () by specifying the open char.
function extractBlock(str, startIdx, open = '{') {
    const close = { '{': '}', '[': ']', '(': ')' }[open];
    const blockStart = str.indexOf(open, startIdx);
    if (blockStart === -1) return null;
    let depth = 1;
    let pos = blockStart + 1;
    while (depth > 0 && pos < str.length) {
        if (str[pos] === open) depth++;
        else if (str[pos] === close) depth--;
        pos++;
    }
    return depth === 0 ? str.substring(blockStart, pos) : null;
}

// ============================================================
// Patch 1: Platform check - allow Linux through fz()
// Pattern: VAR!=="darwin"&&VAR!=="win32" (unique in platform gate)
// Anchor: appears near 'unsupported_platform' code value
// ============================================================
const platformGateRe = /(\w+)(\s*!==\s*"darwin"\s*&&\s*)\1(\s*!==\s*"win32")/g;
const origCode = code;
code = code.replace(platformGateRe, (match, varName, mid, end) => {
    // Only patch the instance near the "unsupported_platform" code value
    const matchIdx = origCode.indexOf(match);
    const nearbyText = origCode.substring(matchIdx, matchIdx + 200);
    if (nearbyText.includes('unsupported_platform') || nearbyText.includes('Unsupported platform')) {
        return `${varName}${mid}${varName}${end}&&${varName}!=="linux"`;
    }
    return match;
});
if (code !== origCode) {
    console.log('  Patched platform check to allow Linux');
    patchCount++;
} else {
    // Try without backreference (in case minifier uses different var names)
    const simpleRe = /(!=="darwin"\s*&&\s*\w+\s*!=="win32")([\s\S]{0,200}unsupported_platform)/;
    const simpleMatch = code.match(simpleRe);
    if (simpleMatch) {
        const varMatch = simpleMatch[0].match(/(\w+)\s*!==\s*"win32"/);
        if (varMatch) {
            code = code.replace(simpleMatch[1],
                simpleMatch[1] + '&&' + varMatch[1] + '!=="linux"');
            console.log('  Patched platform check to allow Linux (fallback)');
            patchCount++;
        }
    }
}
if (code === origCode) {
    console.error('FATAL: Failed to patch cowork platform gate for Linux.');
    console.error('The app will crash at startup without this patch.');
    console.error('The platform check pattern or nearby anchor text may have changed.');
    process.exit(1);
}

// ============================================================
// Patch 2: Module loading - use TypeScript VM client on Linux
// Anchor: unique string "vmClient (TypeScript)"
// Extracts the win32 platform variable, adds Linux OR condition
// ============================================================
const vmClientLogMatch = code.match(/(\w+)(\s*\?\s*"vmClient \(TypeScript\)")/);
if (vmClientLogMatch) {
    const win32Var = vmClientLogMatch[1];

    // 2a: Patch the log/description line
    // FROM: WIN32VAR?"vmClient (TypeScript)"
    // TO:   (WIN32VAR||process.platform==="linux")?"vmClient (TypeScript)"
    // Use negative lookbehind to avoid double-patching
    const logRe = new RegExp(
        '(?<!\\|\\|process\\.platform==="linux"\\))' +
        win32Var.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') +
        '(\\s*\\?\\s*"vmClient \\(TypeScript\\)")'
    );
    if (logRe.test(code)) {
        code = code.replace(logRe,
            '(' + win32Var + '||process.platform==="linux")$1');
        console.log('  Patched VM client log check for Linux');
        patchCount++;
    }

    // 2b: Patch the actual module assignment
    // Beautified: WIN32VAR ? (df = { vm: bYe }) : (df = ...)
    // Minified:   WIN32VAR?df={vm:bYe}:df=...
    // Handle both: outer parens are optional in minified code
    const assignRe = new RegExp(
        '(?<!\\|\\|process\\.platform==="linux"\\)?)' +
        win32Var.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') +
        '(\\s*\\?\\s*\\(?\\s*[\\w$]+\\s*=\\s*\\{\\s*vm\\s*:\\s*[\\w$]+\\s*\\}\\s*\\)?)'
    );
    if (assignRe.test(code)) {
        code = code.replace(assignRe,
            '(' + win32Var + '||process.platform==="linux")$1');
        console.log('  Patched VM module assignment for Linux');
        patchCount++;
    }
} else {
    console.log('  WARNING: Could not find vmClient variable for module loading patch');
}

// ============================================================
// Patch 3: Socket path - use Unix domain socket on Linux
// Anchor: unique string "cowork-vm-service" in pipe path
// ============================================================
const pipeMatch = code.match(/(\w+)(\s*=\s*)"([^"]*\\\\[^"]*cowork-vm-service[^"]*)"/);
if (pipeMatch) {
    const pipeVar = pipeMatch[1];
    const assign = pipeMatch[2];
    const pipeStr = pipeMatch[3];
    const oldExpr = pipeVar + assign + '"' + pipeStr + '"';
    const newExpr = pipeVar + assign +
        'process.platform==="linux"?' +
        '(process.env.XDG_RUNTIME_DIR||"/tmp")+"/cowork-vm-service.sock"' +
        ':"' + pipeStr + '"';
    code = code.replace(oldExpr, newExpr);
    console.log('  Patched socket path for Linux Unix domain socket');
    patchCount++;
} else {
    console.log('  WARNING: Could not find pipe path for socket patch');
}

// ============================================================
// Patch 4: Bundle manifest - add empty Linux entries to files
// The linux key MUST exist to prevent TypeError when the app
// accesses files["linux"]["x64"] during cowork status checks.
// Empty arrays mean no VM files are downloaded — this is correct
// because the VM backend is non-functional on Linux (bwrap is
// the only working backend and doesn't use VM files).
// Note: [].every() returns true (vacuous truth), so iBA() reports
// that VM files are present. That makes the download() IPC
// short-circuit without fetching anything, which is the intent
// here. Patch 4b handles the downstream side-effect on
// getDownloadStatus() so the Cowork tab doesn't auto-select on
// every launch (#341).
// ============================================================
if (!code.includes('"linux":{') && !code.includes("'linux':{") &&
    !code.includes('linux:{')) {
    const shaRe = /sha\s*:\s*"([a-f0-9]{40})"/;
    const shaMatch = code.match(shaRe);
    if (shaMatch) {
        const shaIdx = code.indexOf(shaMatch[0]);
        const afterSha = code.indexOf('files', shaIdx);
        if (afterSha !== -1 && afterSha - shaIdx < 200) {
            const filesBlock = extractBlock(code, afterSha, '{');
            if (filesBlock) {
                const filesEnd = code.indexOf(filesBlock, afterSha)
                    + filesBlock.length;
                const insertPos = filesEnd - 1;
                const linuxEntry = ',linux:{x64:[],arm64:[]}';
                code = code.substring(0, insertPos) +
                    linuxEntry + code.substring(insertPos);
                console.log('  Added empty Linux entries to' +
                    ' bundle manifest (VM download disabled)');
                patchCount++;
            }
        }
    }
    if (!code.includes('linux:{x64:')) {
        console.log('  WARNING: Could not add Linux bundle' +
            ' manifest entries');
    }
}

// ============================================================
// Patch 4b: Suppress Cowork tab auto-selection on launch (#341)
// Anchor: getDownloadStatus() method with readable enum property
//         names (.Downloading, .Ready, .NotDownloaded) — stable
//         across minifier releases.
//
// Patch 4's vacuous-truth workaround makes iBA() report that VM
// files are "ready", which is what short-circuits the download
// path. The side-effect is that getDownloadStatus() also returns
// Ready on every startup, and the remote web app treats a
// startup observation of Ready as the "download just finished"
// transition that auto-navigates to Cowork on macOS/Windows.
// Linux users hit that transition on every launch.
//
// Fix: return NotDownloaded on Linux from getDownloadStatus().
// iBA() is left alone so download() still short-circuits, and
// clicking the Cowork tab still works (the web app's setup flow
// calls download() which returns success immediately).
// ============================================================
{
    const statusRe = /getDownloadStatus\(\)\{return\s+(\w+\(\)\?(\w+)\.Downloading:\w+\(\)\?\2\.Ready:\2\.NotDownloaded)\}/;
    const statusMatch = code.match(statusRe);
    if (statusMatch) {
        const [whole, origExpr, enumVar] = statusMatch;
        const replacement =
            'getDownloadStatus(){return process.platform==="linux"?' +
            enumVar + '.NotDownloaded:' + origExpr + '}';
        code = code.replace(whole, replacement);
        console.log('  Patched getDownloadStatus to return ' +
            'NotDownloaded on Linux (suppresses auto-nav, #341)');
        patchCount++;
    } else if (code.includes(
        'getDownloadStatus(){return process.platform==="linux"?'
    )) {
        console.log('  Cowork auto-nav suppression already applied');
    } else {
        console.log('  WARNING: Could not find getDownloadStatus' +
            ' pattern for auto-nav suppression (#341)');
    }
}

// ============================================================
// Patch 5: MSIX check bypass for Linux
// The fz() function checks: if(t==="win32"&&!ga()) for MSIX
// This is already gated to win32, so no change needed.
// ============================================================

// ============================================================
// Patch 6: Auto-launch service daemon on first connection attempt
// Anchor: unique string "VM service not running. The service failed to start."
//
// The retry loop only retries on ENOENT (socket missing). On Linux,
// stale sockets from a previous session give ECONNREFUSED instead,
// which causes an immediate throw with no retry or auto-launch.
//
// Fix: patch the ENOENT check to also match ECONNREFUSED on Linux,
// then inject auto-launch before the retry delay.
//
// The auto-launch uses a timestamp-based cooldown (_lastSpawn) instead
// of a one-shot boolean so the daemon can be re-spawned after it dies
// mid-session (issue #408). 10s cooldown prevents fork storms on hard
// failures while allowing recovery on the next retry iteration.
//
// stdout/stderr of the forked daemon is piped to
// ~/.config/Claude/logs/cowork_vm_daemon.log so crashes are no longer
// silent. Falls back to "ignore" if the log dir can't be opened.
// ============================================================
const serviceErrorStr = 'VM service not running. The service failed to start.';
const serviceErrorIdx = code.lastIndexOf(serviceErrorStr);
if (serviceErrorIdx !== -1) {
    // Step 1: Find the ENOENT check and expand it to include ECONNREFUSED
    // Pattern: VAR.code==="ENOENT"
    // Search backwards from the error string to find it
    const searchStart = Math.max(0, serviceErrorIdx - 300);
    const beforeRegion = code.substring(searchStart, serviceErrorIdx);
    const enoentRe = /(\w+)\.code\s*===\s*"ENOENT"/g;
    let enoentMatch;
    let lastEnoent = null;
    while ((enoentMatch = enoentRe.exec(beforeRegion)) !== null) {
        lastEnoent = enoentMatch;
    }
    if (lastEnoent) {
        const enoentStr = lastEnoent[0];
        const errVar = lastEnoent[1];
        const enoentAbsIdx = searchStart + lastEnoent.index;
        // Replace: VAR.code==="ENOENT"
        // With:    (VAR.code==="ENOENT"||process.platform==="linux"&&VAR.code==="ECONNREFUSED")
        const expanded =
            '(' + enoentStr +
            '||process.platform==="linux"&&' + errVar + '.code==="ECONNREFUSED")';
        code = code.substring(0, enoentAbsIdx) +
            expanded +
            code.substring(enoentAbsIdx + enoentStr.length);
        console.log('  Expanded ENOENT check to include ECONNREFUSED on Linux');
    } else {
        console.log('  WARNING: Could not find ENOENT check for ECONNREFUSED expansion');
    }

    // Step 2: Inject auto-launch before the retry delay
    // Re-find serviceErrorStr since indices shifted after step 1
    const newServiceErrorIdx = code.lastIndexOf(serviceErrorStr);
    const searchEnd = Math.min(code.length, newServiceErrorIdx + 300);
    const searchRegion = code.substring(newServiceErrorIdx, searchEnd);
    const retryMatch = searchRegion.match(
        /await new Promise\(([\w$]+)=>\s*setTimeout\(\1,\s*([\w$]+)\)\)/
    );
    if (retryMatch) {
        const retryStr = retryMatch[0];
        const retryOffset = searchRegion.indexOf(retryStr);
        const retryAbsIdx = newServiceErrorIdx + retryOffset;
        // Inject auto-launch before the retry delay
        // Service script is in app.asar.unpacked/ (not inside asar, since
        // child_process cannot execute scripts from inside an asar).
        // Uses fork() instead of spawn() because process.execPath in Electron
        // is the Electron binary - spawn would trigger "file open" handling
        // instead of executing the script as Node.js.
        const svcPath = process.env.SVC_PATH || 'cowork-vm-service.js';
        // Extract the enclosing function name (Ma or whatever it's
        // minified to) so the dedup guard attaches to it
        const funcSearchStart = Math.max(0, newServiceErrorIdx - 2000);
        const funcRegion = code.substring(funcSearchStart, newServiceErrorIdx);
        // The function is defined as: async function NAME(t,e){...for(let r=0;r<=LIMIT;r++)
        const funcNameRe = /async function (\w+)\s*\(\s*\w+\s*,\s*\w+\s*\)\s*\{[\s\S]*?for\s*\(\s*let/g;
        let funcMatch;
        let retryFuncName = null;
        while ((funcMatch = funcNameRe.exec(funcRegion)) !== null) {
            retryFuncName = funcMatch[1];
        }
        const spawnGuard = retryFuncName
            ? retryFuncName + '._lastSpawn'
            : '_globalLastSpawn';
        // Cooldown in ms — long enough to avoid fork storms, short enough
        // that the retry loop can re-spawn after a mid-session daemon death.
        const autoLaunch =
            'process.platform==="linux"&&' +
            '(!' + spawnGuard + '||Date.now()-' + spawnGuard + '>1e4)' +
            '&&(' + spawnGuard + '=Date.now(),' +
            '(()=>{try{' +
            'const _p=require("path"),_fs=require("fs");' +
            'const _d=_p.join(process.resourcesPath,' +
            '"app.asar.unpacked","' + svcPath + '");' +
            'if(_fs.existsSync(_d)){' +
            // Open daemon log for append; fall back to ignoring stdio.
            'let _stdio="ignore";' +
            'try{' +
            'const _ld=_p.join(process.env.HOME||"/tmp",' +
            '".config/Claude/logs");' +
            '_fs.mkdirSync(_ld,{recursive:true});' +
            'const _fd=_fs.openSync(' +
            '_p.join(_ld,"cowork_vm_daemon.log"),"a");' +
            '_stdio=["ignore",_fd,_fd,"ipc"]' +
            '}catch(_){}' +
            'const _c=require("child_process").fork(_d,[],' +
            '{detached:true,stdio:_stdio,env:{...process.env,' +
            'ELECTRON_RUN_AS_NODE:"1"}});' +
            'global.__coworkDaemonPid=_c.pid;_c.unref()}' +
            '}catch(_e){console.error("[cowork-autolaunch]",_e)}})()),';
        code = code.substring(0, retryAbsIdx) +
            autoLaunch + code.substring(retryAbsIdx);
        console.log('  Added service daemon auto-launch on Linux');
        patchCount++;
    } else {
        console.log('  WARNING: Could not find retry delay for auto-launch patch');
    }
} else {
    console.log('  WARNING: Could not find VM service error string for auto-launch');
}

// ============================================================
// Patch 6b: Extend auto-reinstall delete list (issue #408)
// Anchor: const NAME=["rootfs.img",...] — the module-level array
// driving the reinstall-files cleanup in _ue()/deleteVMBundle().
//
// Upstream preserves sessiondata.img and rootfs.img.zst across
// auto-reinstall to avoid re-download. On 1.2773.0, preserving
// them puts the daemon into an unstartable state that persists
// across app restarts and OS reboots. Trade-off: next startup
// re-downloads/re-extracts these files. This only runs on the
// auto-reinstall path (already in a failed state), so biasing
// toward recovery over re-download avoidance is correct.
// ============================================================
{
    const reinstallArrRe = /const (\w+)=\[("rootfs\.img"[^\]]*)\];/;
    const arrMatch = code.match(reinstallArrRe);
    if (arrMatch) {
        const [whole, name, contents] = arrMatch;
        const additions = [];
        if (!contents.includes('"sessiondata.img"')) {
            additions.push('"sessiondata.img"');
        }
        if (!contents.includes('"rootfs.img.zst"')) {
            additions.push('"rootfs.img.zst"');
        }
        if (additions.length) {
            const newContents = contents + ',' + additions.join(',');
            code = code.replace(
                whole,
                'const ' + name + '=[' + newContents + '];'
            );
            console.log('  Added VM images to reinstall delete list');
            patchCount++;
        } else {
            console.log('  Reinstall delete list already includes VM images');
        }
    } else {
        console.log('  WARNING: Could not find reinstall file list array');
    }
}

// ============================================================
// Patch 7: Skip Windows-specific smol-bin.vhdx copy on Linux
// The code already checks: if(process.platform==="win32")
// No change needed - win32-gated code is skipped on Linux.
// ============================================================

// ============================================================
// Patch 8: VM download tmpdir fix for Linux
// On Linux, os.tmpdir() returns /tmp which is often a small
// tmpfs (3-4GB). The VM rootfs download decompresses to ~9GB,
// causing ENOSPC. Patch to use the bundle directory (on real
// disk) instead of tmpfs for the download temp files.
// Anchor: unique string "wvm-" in mkdtemp call
// Strategy: find the bundle dir variable from nearby mkdir(),
// then replace tmpdir() with that variable in the mkdtemp call.
// ============================================================
{
    // Find: MKDTEMP(PATH.join(OS.tmpdir(), "wvm-"))
    // The bundle dir var is used in mkdir(VAR, ...) just before
    const mkdtempRe = /(\w+)\.mkdtemp\(\s*(\w+)\.join\(\s*(\w+)\.tmpdir\(\)\s*,\s*"wvm-"\s*\)\s*\)/;
    const mkdtempMatch = code.match(mkdtempRe);
    if (mkdtempMatch) {
        const [fullMatch, fsVar, pathVar, osVar] = mkdtempMatch;
        // Find the bundle dir variable: mkdir(VAR, { recursive before wvm-
        const mkdtempIdx = code.indexOf(fullMatch);
        const searchStart = Math.max(0, mkdtempIdx - 2000);
        const before = code.substring(searchStart, mkdtempIdx);
        // Look for: mkdir(VARNAME, { recursive
        const mkdirRe = /(\w+)\.mkdir\(\s*(\w+)\s*,\s*\{\s*recursive/g;
        let bundleVar = null;
        let lastMkdir;
        while ((lastMkdir = mkdirRe.exec(before)) !== null) {
            bundleVar = lastMkdir[2];
        }
        if (bundleVar) {
            // Replace os.tmpdir() with the bundle dir variable
            // On Linux, use the bundle dir; on other platforms keep tmpdir
            const replacement =
                `${fsVar}.mkdtemp(${pathVar}.join(` +
                `process.platform==="linux"?${bundleVar}:${osVar}.tmpdir(),` +
                `"wvm-"))`;
            code = code.substring(0, mkdtempIdx) + replacement +
                code.substring(mkdtempIdx + fullMatch.length);
            console.log('  Patched VM download temp dir to use bundle path on Linux');
            patchCount++;
        } else {
            console.log('  WARNING: Could not find bundle dir variable for tmpdir patch');
        }
    } else {
        console.log('  WARNING: Could not find mkdtemp("wvm-") for tmpdir patch');
    }
}

// ============================================================
// Patch 9: Copy smol-bin VHDX on Linux
// The win32 block copies smol-bin then calls _.configure()
// (Windows HCS setup) which causes "Request timed out" on
// Linux (#315). Inject a separate Linux block after the win32
// block that only does the smol-bin copy.
// Variable names are extracted dynamically from the win32 block
// since minified names change between releases (#344).
// ============================================================
{
    const anchor = '"[VM:start] Windows VM service configured"';
    const anchorIdx = code.indexOf(anchor);
    if (anchorIdx !== -1) {
        // Find the "}" closing the win32 if-block after the anchor
        const closingBrace = code.indexOf('}', anchorIdx + anchor.length);
        if (closingBrace !== -1) {
            // Extract minified variable names from the win32 block
            // Search backwards from anchor to find the win32 block
            const regionStart = Math.max(0, anchorIdx - 1000);
            const region = code.substring(regionStart, anchorIdx);

            // JS identifier may start with $, _, or letter; \w doesn't
            // match $ so use [$\w]+ to capture vars like `$e` (Claude
            // >= 1.3109.0 uses $e for the fs module to avoid collision
            // with the parameter `e`). See issue #418.
            // path var: VAR.join(process.resourcesPath,
            const pathMatch = region.match(
                /([$\w]+)\.join\(\s*process\.resourcesPath\s*,/
            );
            // fs var: VAR.existsSync(
            const fsMatch = region.match(/([$\w]+)\.existsSync\(/);
            // logger var: VAR.info("[VM:start]
            const logMatch = region.match(
                /([$\w]+)\.info\(\s*[`"]\[VM:start\]/
            );
            // stream/pipeline var: VAR.pipeline(
            const streamMatch = region.match(/([$\w]+)\.pipeline\(/);
            // arch function: const VAR=FUNC(), used in smol-bin
            const archMatch = region.match(
                /const\s+([$\w]+)\s*=\s*([$\w]+)\(\)\s*,\s*[$\w]+\s*=\s*[$\w]+\.join/
            );
            // bundlePath var: PATH.join(VAR,"smol-bin.vhdx")
            const bundleMatch = region.match(
                /\.join\(\s*([$\w]+)\s*,\s*"smol-bin\.vhdx"\s*\)/
            );

            if (pathMatch && fsMatch && logMatch &&
                streamMatch && archMatch && bundleMatch) {
                const pathVar = pathMatch[1];
                const fsVar = fsMatch[1];
                const logVar = logMatch[1];
                const streamVar = streamMatch[1];
                const archFunc = archMatch[2];
                const bundleVar = bundleMatch[1];

                const linuxBlock =
                    'if(process.platform==="linux"){' +
                    'const _la=' + archFunc + '(),' +
                    '_ls=' + pathVar + '.join(process.resourcesPath,' +
                        '`smol-bin.${_la}.vhdx`),' +
                    '_ld=' + pathVar + '.join(' + bundleVar +
                        ',"smol-bin.vhdx");' +
                    fsVar + '.existsSync(_ls)?' +
                    '(' + logVar + '.info(' +
                        '`[VM:start] Copying smol-bin.${_la}' +
                        '.vhdx to bundle (Linux)`),' +
                    'await ' + streamVar + '.pipeline(' +
                        fsVar + '.createReadStream(_ls),' +
                        fsVar + '.createWriteStream(_ld)),' +
                    logVar + '.info(' +
                        '`[VM:start] smol-bin.${_la}' +
                        '.vhdx copied successfully`))' +
                    ':' + logVar + '.warn(' +
                        '`[VM:start] smol-bin.${_la}' +
                        '.vhdx not found at ${_ls}`)' +
                    '}';
                // Defensive: if a future upstream emits its own
                // if(process.platform==="linux"){...} block right
                // after the win32 close brace, strip it before
                // injecting our correctly-wired linuxBlock so we
                // don't end up with two competing blocks.
                const insertPos = closingBrace + 1;
                let stripUntil = insertPos;
                const afterWin32 = code.substring(insertPos);
                const upstreamRe = /^\s*if\s*\(\s*process\.platform\s*===\s*"linux"\s*\)\s*\{/;
                const upstreamMatch = afterWin32.match(upstreamRe);
                if (upstreamMatch) {
                    const matchEnd = insertPos + upstreamMatch[0].length;
                    let depth = 1, pos = matchEnd;
                    while (depth > 0 && pos < code.length) {
                        if (code[pos] === '{') depth++;
                        else if (code[pos] === '}') depth--;
                        pos++;
                    }
                    if (depth === 0) {
                        stripUntil = pos;
                        console.log('  Stripped pre-existing upstream Linux block');
                    } else {
                        console.log('  WARNING: Upstream Linux block found but braces unbalanced; not stripping');
                    }
                }
                code = code.substring(0, insertPos) +
                    linuxBlock +
                    code.substring(stripUntil);
                console.log('  Injected Linux smol-bin copy block (skips _.configure)');
                console.log(`    vars: path=${pathVar} fs=${fsVar} log=${logVar} stream=${streamVar} arch=${archFunc} bundle=${bundleVar}`);
                patchCount++;
            } else {
                const missing = [];
                if (!pathMatch) missing.push('path');
                if (!fsMatch) missing.push('fs');
                if (!logMatch) missing.push('logger');
                if (!streamMatch) missing.push('stream');
                if (!archMatch) missing.push('arch');
                if (!bundleMatch) missing.push('bundlePath');
                console.log(`  WARNING: Could not extract minified variable(s): ${missing.join(', ')}`);
            }
        } else {
            console.log('  WARNING: Could not find closing brace after Windows VM service anchor');
        }
    } else {
        console.log('  WARNING: Could not find Windows VM service anchor for smol-bin patch');
    }
}

// ============================================================
// Patch 10: Register quit handler for cowork daemon cleanup
// The upstream vm-shutdown handler uses a Swift addon unavailable
// on Linux. Register our own to SIGTERM the daemon on app quit.
// ============================================================
{
    const quitFnRe = /registerQuitHandler:\s*(\w+)/;
    const quitFnMatch = code.match(quitFnRe);
    if (quitFnMatch) {
        const quitFn = quitFnMatch[1];
        console.log('  Found registerQuitHandler function: ' + quitFn);

        const quitFnDef = 'function ' + quitFn + '(';
        const quitFnDefIdx = code.indexOf(quitFnDef);
        if (quitFnDefIdx !== -1) {
            const fnBlock = extractBlock(code, quitFnDefIdx, '{');
            if (fnBlock) {
                const insertIdx = code.indexOf(fnBlock, quitFnDefIdx) +
                    fnBlock.length;
                const shutdownHandler =
                    'process.platform==="linux"&&' + quitFn + '({' +
                    'name:"cowork-linux-daemon-shutdown",' +
                    'fn:async()=>{' +
                    'const _p=global.__coworkDaemonPid;' +
                    'if(!_p)return;' +
                    'try{const _cmd=require("fs").readFileSync(' +
                    '"/proc/"+_p+"/cmdline","utf8");' +
                    'if(!_cmd.includes("cowork-vm-service"))return' +
                    '}catch(_e){return}' +
                    'try{process.kill(_p,"SIGTERM")}catch(_e){return}' +
                    'for(let _i=0;_i<50;_i++){' +
                    'await new Promise(_r=>setTimeout(_r,200));' +
                    'try{process.kill(_p,0)}catch(_e){return}' +
                    '}}});';
                code = code.substring(0, insertIdx) +
                    shutdownHandler + code.substring(insertIdx);
                console.log('  Registered Linux cowork daemon quit handler');
                patchCount++;
            } else {
                console.log('  WARNING: Could not find ' + quitFn +
                    ' function body for quit handler');
            }
        } else {
            console.log('  WARNING: Could not find ' + quitFn +
                ' function definition');
        }
    } else {
        console.log('  WARNING: Could not find registerQuitHandler' +
            ' export for quit handler');
    }
}

// ============================================================
// Patch 12: Forward user-selected folder as sharedCwdPath (#412)
// The cowork-vm-service daemon honors a sharedCwdPath field on
// the spawn IPC payload with priority over cwd (resolveWorkDir
// in scripts/cowork-vm-service.js), but upstream never populates
// it on Linux, so the daemon falls back to mountMap heuristics
// (#389/#392/#411). Thread the user's folder through three sites:
//   12a. getVMSpawnFunction({...}) config — inject sharedCwdPath.
//   12b. Kyr() -> VMClient.spawn() call — forward as 13th arg.
//   12c. spawn() body — accept trailing param, set on IPC payload.
// Daemon-side mount heuristic from #392 remains as fallback.
// ============================================================
{
    // --- 12a: inject sharedCwdPath into getVMSpawnFunction config ---
    let site1Done = false;
    const cfgAnchor = 'this.getVMSpawnFunction(';
    const cfgIdx = code.indexOf(cfgAnchor);
    if (cfgIdx === -1) {
        console.log('  WARNING: #412 getVMSpawnFunction anchor not found');
    } else {
        // The argument is a {...} object literal; extract it directly.
        const cfgBlock = extractBlock(code, cfgIdx + cfgAnchor.length, '{');
        if (!cfgBlock) {
            console.log('  WARNING: #412 getVMSpawnFunction {...} not found');
        } else if (cfgBlock.includes('sharedCwdPath')) {
            console.log('  #412 sharedCwdPath already in spawn config');
            site1Done = true;
        } else {
            // The session-id var is the value of the first field
            // 'sessionId:VAR' in the config itself — cheap, scoped, and
            // immune to unrelated *.userSelectedFolders references (e.g.
            // loop variables) that wander into the enclosing scope.
            const sidMatch = cfgBlock.match(/\{sessionId:(\w+)\b/);
            if (!sidMatch) {
                console.log('  WARNING: #412 no sessionId field in config');
            } else {
                const sidVar = sidMatch[1];
                // Route through this.sessions.get() — canonical accessor
                // the same class already uses, so the injection survives
                // re-orderings of local vars in the enclosing function.
                const blockStart = code.indexOf(cfgBlock, cfgIdx);
                const insertAt = blockStart + cfgBlock.length - 1;
                const insertion = ',sharedCwdPath:this.sessions.get(' +
                    sidVar + ')?.userSelectedFolders?.[0]';
                code = code.substring(0, insertAt) +
                    insertion + code.substring(insertAt);
                console.log('  Injected sharedCwdPath into spawn' +
                    ' config (sessionId var: ' + sidVar + ')');
                patchCount++;
                site1Done = true;
            }
        }
    }

    // --- 12c: accept a 13th param in spawn() method body ---
    let site3Done = false;
    const spawnIdempotent =
        /async spawn\([^)]+\)\{const \w+=\{id:[^}]+\};[^{}]*\.sharedCwdPath=/;
    if (spawnIdempotent.test(code)) {
        console.log('  #412 spawn method already accepts sharedCwdPath');
        site3Done = true;
    } else {
        // Match the spawn body with the trailing mountConda setter and the
        // IPC call. Captures: arg list, payload var, setter chain, IPC tail.
        const spawnRe =
            /async spawn\(([^)]+)\)\{const (\w+)=\{id:[^}]+\};([^{}]*?\w+&&\(\2\.mountConda=\w+\)),(await \w+\("spawn",\2\)\})/;
        const spawnMatch = code.match(spawnRe);
        if (!spawnMatch) {
            console.log('  WARNING: #412 spawn method body regex did not match');
        } else {
            const [whole, argList, payloadVar, setters, tail] = spawnMatch;
            const argNames = new Set(argList.split(',').map(s =>
                s.split('=')[0].trim()));
            let param = null;
            for (const c of 'hHpPqQxXyYzZkKmMwW') {
                if (!argNames.has(c)) { param = c; break; }
            }
            if (!param) {
                console.log('  WARNING: #412 no unused letter for spawn param');
            } else {
                const newSetters = setters + ',' + param + '&&(' +
                    payloadVar + '.sharedCwdPath=' + param + ')';
                const assembled = whole
                    .replace('async spawn(' + argList + ')',
                        'async spawn(' + argList + ',' + param + ')')
                    .replace(setters + ',' + tail, newSetters + ',' + tail);
                code = code.slice(0, spawnMatch.index) + assembled +
                    code.slice(spawnMatch.index + whole.length);
                console.log('  Extended spawn() with ' + param +
                    ' -> ' + payloadVar + '.sharedCwdPath setter');
                patchCount++;
                site3Done = true;
            }
        }
    }

    // --- 12b: forward SESSION.sharedCwdPath in Kyr -> spawn() call ---
    // Anchor: ',VAR.mountConda)' — expected unique to the 12-arg caller
    // (the shorter 10-arg one-shot call sites lack mountConda). Assert
    // the uniqueness so a second upstream caller wouldn't silently take
    // only the first hit.
    let site2Done = false;
    if (/,\w+\.mountConda,\w+\.sharedCwdPath\)/.test(code)) {
        console.log('  #412 caller already forwards sharedCwdPath');
        site2Done = true;
    } else {
        const callMatches = [...code.matchAll(/,(\w+)\.mountConda\)/g)];
        if (callMatches.length === 0) {
            console.log('  WARNING: #412 no ",VAR.mountConda)" pattern found');
        } else if (callMatches.length > 1) {
            console.log('  WARNING: #412 expected 1 ",VAR.mountConda)" match,' +
                ' found ' + callMatches.length + '; skipping to avoid' +
                ' wrong-site forwarding');
        } else {
            const [whole, sessionVar] = callMatches[0];
            code = code.replace(whole, ',' + sessionVar +
                '.mountConda,' + sessionVar + '.sharedCwdPath)');
            console.log('  Forwarded sharedCwdPath in Kyr->spawn call' +
                ' (var: ' + sessionVar + ')');
            patchCount++;
            site2Done = true;
        }
    }

    if (!site1Done || !site2Done || !site3Done) {
        console.log('  WARNING: #412 partial — site1=' + site1Done +
            ' site2=' + site2Done + ' site3=' + site3Done +
            '; daemon fallback still active');
    }
}

fs.writeFileSync(indexJs, code);
console.log(`  Applied ${patchCount} cowork patches`);
if (patchCount < 5) {
    console.log('  WARNING: Some patches failed - Cowork mode may not work');
}
COWORK_PATCH
	then
		echo 'WARNING: Cowork Linux patches failed' >&2
		echo 'Cowork mode may not be available on Linux' >&2
	fi

	echo '##############################################################'
}

install_node_pty() {
	section_header 'Installing node-pty for terminal support'

	local pty_src_dir=''

	if [[ -n $node_pty_dir ]]; then
		# Use pre-built node-pty (e.g. from Nix)
		echo "Using pre-built node-pty from $node_pty_dir"
		pty_src_dir="$node_pty_dir"
	else
		# Build node-pty from npm
		node_pty_build_dir="$work_dir/node-pty-build"
		mkdir -p "$node_pty_build_dir" || exit 1
		cd "$node_pty_build_dir" || exit 1
		echo '{"name":"node-pty-build","version":"1.0.0","private":true}' > package.json

		echo 'Installing node-pty (this compiles native module)...'
		if npm install node-pty 2>&1; then
			echo 'node-pty installed successfully'
			pty_src_dir="$node_pty_build_dir/node_modules/node-pty"
		else
			echo 'Failed to install node-pty - terminal features may not work'
		fi
	fi

	if [[ -n $pty_src_dir && -d $pty_src_dir ]]; then
		echo 'Copying node-pty JavaScript files into app.asar.contents...'
		mkdir -p "$app_staging_dir/app.asar.contents/node_modules/node-pty" || exit 1
		# --no-preserve=mode so read-only bits from the Nix store
		# (--node-pty-dir) don't propagate into the staging tree.
		cp -r --no-preserve=mode "$pty_src_dir/lib" \
			"$app_staging_dir/app.asar.contents/node_modules/node-pty/" || exit 1
		cp --no-preserve=mode "$pty_src_dir/package.json" \
			"$app_staging_dir/app.asar.contents/node_modules/node-pty/" || exit 1
		# Also stage build/ so `asar pack --unpack '**/*.node'` can
		# create a properly-tracked .unpacked entry. Without this,
		# the asar manifest has no node-pty/build/ entry and
		# Electron's asar->.unpacked redirect never fires, so
		# require('../build/Release/pty.node') from inside the asar
		# fails with MODULE_NOT_FOUND even when the binary exists
		# in app.asar.unpacked/.
		if [[ -d $pty_src_dir/build ]]; then
			cp -r --no-preserve=mode "$pty_src_dir/build" \
				"$app_staging_dir/app.asar.contents/node_modules/node-pty/" || exit 1
			echo 'node-pty build/ staged (will be unpacked during asar pack)'
		fi
		echo 'node-pty JavaScript files copied'
	elif [[ -z $pty_src_dir ]]; then
		echo 'node-pty source directory not set'
	else
		echo "node-pty directory not found: $pty_src_dir"
	fi

	cd "$app_staging_dir" || exit 1
	section_footer 'node-pty installation'
}
