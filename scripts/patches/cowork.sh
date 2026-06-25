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

# ---------------------------------------------------------------------------
# Patch: reject .asar paths in the directory-check helper
#
# On Linux, app.asar is passed as an argv element to Electron. The
# directory-check function (wFA in the current build) calls
# fs.statSync(path).isDirectory(). Electron's ASAR virtual filesystem
# shim makes .asar archives report isDirectory()===true, so app.asar
# is dispatched to Cowork as a "folder drop". This causes:
#   - Permission dialog on every launch (#383)
#   - Forced Cowork mode (#622)
#   - Fatal --add-dir error in Claude Code >=2.1.111 (#632)
#
# Fix: inject !PARAM.endsWith(".asar")&& before the statSync call.
# This runs independently of the Cowork-mode guard (the function
# exists even if Cowork code is absent).
# ---------------------------------------------------------------------------
patch_asar_path_filter() {
	echo 'Patching directory check to reject .asar paths...'
	local index_js='app.asar.contents/.vite/build/index.js'

	if ! INDEX_JS="$index_js" node << 'ASAR_FILTER_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
let code = fs.readFileSync(indexJs, 'utf8');

// Find the directory-check helper function.
// Beautified form:
//   function wFA(e) {
//     try { return ee.statSync(e).isDirectory(); }
//     catch { return !1; }
//   }
// Minified form:
//   function wFA(e){try{return ee.statSync(e).isDirectory()}catch{return!1}}
//
// Stable anchors: .statSync( ).isDirectory() inside try/catch returning !1.
// The function name, parameter, and fs variable are all minified.
const dirCheckRe =
    /function\s+([\w$]+)\s*\(\s*([\w$]+)\s*\)\s*\{\s*try\s*\{\s*return\s+([\w$]+)\.statSync\(\s*\2\s*\)\.isDirectory\(\)/;
const match = code.match(dirCheckRe);

if (!match) {
    console.error('FATAL: Could not find directory-check function' +
        ' (statSync+isDirectory pattern).');
    console.error('This patch prevents .asar paths from triggering' +
        ' false Cowork dispatch (#383, #622, #632).');
    process.exit(1);
}

const [, funcName, paramName] = match;
console.log('  Found directory-check function: ' + funcName +
    '(' + paramName + ')');

// Idempotency: check if already patched
if (code.includes('.endsWith(".asar")')) {
    console.log('  .asar path filter already applied');
    process.exit(0);
}

// Insert the guard: !PARAM.endsWith(".asar")&&
// Before: return FSVAR.statSync(PARAM).isDirectory()
// After:  return!PARAM.endsWith(".asar")&&FSVAR.statSync(PARAM).isDirectory()
//
// The replacement is scoped to the matched function via the full
// regex match, so it cannot accidentally hit other statSync calls.
code = code.replace(dirCheckRe, (whole, fn, param, fsVar) => {
    return 'function ' + fn + '(' + param + '){try{return!' +
        param + '.endsWith(".asar")&&' +
        fsVar + '.statSync(' + param + ').isDirectory()';
});

// Verify the patch landed
if (!code.includes('.endsWith(".asar")')) {
    console.error('FATAL: .asar path filter replacement failed.');
    process.exit(1);
}

fs.writeFileSync(indexJs, code);
console.log('  Added .asar path rejection to ' + funcName + '()');
ASAR_FILTER_PATCH
	then
		echo 'FATAL: .asar path filter patch failed' >&2
		echo 'The app will show permission dialogs and may crash' \
			'without this patch (#383, #622, #632).' >&2
		exit 1
	fi

	echo '##############################################################'
}

# ---------------------------------------------------------------------------
# Patch: reject .asar paths in the argv file-drop collector
#
# PR #640 patched the directory-check helper (isDirectory path) so
# app.asar is no longer dispatched as a "folder drop".  However, the
# argv collector function (lKr in the current build) has a separate
# branch:
#
#   if (!i.startsWith("-") && FSVAR.existsSync(i)) { A.push(i); }
#
# Electron's ASAR VFS shim makes existsSync return true for .asar
# paths, so app.asar passes this check and is dispatched to the
# "file drop" handler (cCA), triggering a permission prompt on every
# window close+reopen (#383, #622 regression in v2.0.16+).
#
# Fix: inject !PARAM.endsWith(".asar")&& before the existsSync call.
#
# Threat model: this argv path is reachable from user-launched
# invocations (TPr's only caller is the second-instance handler, and
# the desktop entries ship `Exec=... %u`), so it is not just the app's
# own relaunch. The exact-suffix, case-sensitive ".asar" match is still
# correct because the only sink here is attach-to-draft
# (dispatchOnCoworkFromMain -> selectedFiles) — identical to a manual
# drag, with no content read, privilege boundary, or traversal sink. So
# don't "harden" it with toLowerCase(): that would diverge from the
# sibling .asar guards for zero behavioral gain.
# ---------------------------------------------------------------------------
patch_asar_argv_file_drop_guard() {
	echo 'Patching argv file-drop collector to reject .asar paths...'
	local index_js='app.asar.contents/.vite/build/index.js'

	# Idempotency: check for the guard in context — specifically
	# !PARAM.startsWith("-")&&!PARAM.endsWith(".asar") — anchored to
	# startsWith to avoid false-positive matches from other .asar guards
	# (e.g. the statSync patch or the --add-dir filter).
	if grep -qP '\.startsWith\("-"\)\s*&&\s*![\w$]+\.endsWith\("\.asar"\)' \
		"$index_js"; then
		echo '  .asar file-drop guard already present (idempotent)'
		echo '##############################################################'
		return
	fi

	if ! INDEX_JS="$index_js" node << 'ASAR_FILE_DROP_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
let code = fs.readFileSync(indexJs, 'utf8');

// Find the argv file-drop collector branch.
// Beautified form:
//   if (!i.startsWith("-") && ee.existsSync(i)) {
//     A.push(i);
//     continue;
//   }
// Minified form:
//   if(!i.startsWith("-")&&ee.existsSync(i)){A.push(i);continue}
//
// Anchor: !PARAM.startsWith("-")&&FSVAR.existsSync(PARAM) — unique in
// the bundle (verified). The .push() suffix is intentionally omitted
// to avoid brittleness if the minifier reorders the if-body.
// The param variable and fs variable are both minified and captured.
const re =
    /(![\w$]+\.startsWith\s*\(\s*"-"\s*\)\s*&&\s*)([\w$]+)\.existsSync\(\s*([\w$]+)\s*\)/;
const match = code.match(re);

if (!match) {
    console.error('FATAL: argv file-drop collector branch not found.');
    console.error('  Expected: !PARAM.startsWith("-")&&FSVAR.existsSync(PARAM)');
    console.error(
        '  This patch prevents app.asar file-drop prompts (#383, #622).');
    process.exit(1);
}

// Verify uniqueness — startsWith("-")&&existsSync must appear exactly
// once; multiple matches would mean we cannot safely target this site.
const escaped = match[0].replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const allMatches = code.match(new RegExp(escaped, 'g'));
if (allMatches && allMatches.length > 1) {
    console.error('FATAL: file-drop pattern matched ' +
        allMatches.length + ' times (expected 1).');
    process.exit(1);
}

const [, startsPart, fsVar, param] = match;
console.log(
    '  Found collector: param=' + param + ', fsVar=' + fsVar);

// Insert guard: !PARAM.endsWith(".asar")&&
// Before: !PARAM.startsWith("-")&&FSVAR.existsSync(PARAM)
// After:  !PARAM.startsWith("-")&&!PARAM.endsWith(".asar")&&FSVAR.existsSync(PARAM)
//
// Replace the full outer match directly — no nested replace — to avoid
// any risk of $ in minified identifiers being misread as replacement
// pattern metacharacters.
const patched = startsPart + '!' + param + '.endsWith(".asar")&&' +
    fsVar + '.existsSync(' + param + ')';
code = code.replace(match[0], patched);

// Verify the patch landed with the correct context
if (!code.match(/\.startsWith\("-"\)\s*&&\s*![\w$]+\.endsWith\("\.asar"\)/)) {
    console.error('FATAL: .asar file-drop guard replacement failed.');
    process.exit(1);
}

fs.writeFileSync(indexJs, code);
console.log('  Added .asar guard to argv file-drop collector');
ASAR_FILE_DROP_PATCH
	then
		echo 'FATAL: .asar argv file-drop guard patch failed' >&2
		echo 'The app will show file-drop prompts on window reopen' \
			'without this patch (#383, #622).' >&2
		exit 1
	fi

	echo '##############################################################'
}

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
// Patch 1: VM-supported gate - allow Linux through startVM
// Upstream 1.13576+ replaced the old darwin/win32 platform gate
// with a feature-flag gate ("yukonSilver") inside startVM (VF):
//   const{yukonSilver:r}=D_();
//   if((r==null?void 0:r.status)!=="supported"){...return}
// On Linux the flag is never "supported", so startVM bails before
// it ever talks to our daemon. Anchor on the unique log string
// "[startVM] VM not supported" to locate the guard, then make Linux
// bypass the support check (mirrors the old "allow Linux through"
// intent). This is load-bearing — FATAL on miss.
// ============================================================
{
    const gateAnchor = '[startVM] VM not supported';
    const gateIdx = code.indexOf(gateAnchor);
    if (/process\.platform!=="linux"&&\([\w$]+==null\?void 0:[\w$]+\.status\)!=="supported"/.test(code)) {
        console.log('  VM-supported Linux gate already applied (Patch 1)');
    } else if (gateIdx === -1) {
        console.error('FATAL: Could not find startVM support-gate anchor.');
        console.error('The app will crash at startup without this patch.');
        console.error('The "[startVM] VM not supported" anchor may have changed.');
        process.exit(1);
    } else {
        // Find the nearest yukonSilver support check before the anchor.
        const winStart = Math.max(0, gateIdx - 200);
        const region = code.substring(winStart, gateIdx);
        const supRe = /if\(\(([\w$]+)==null\?void 0:\1\.status\)!=="supported"\)/g;
        let m, last = null;
        while ((m = supRe.exec(region)) !== null) last = m;
        if (!last) {
            console.error('FATAL: Could not find yukonSilver support check.');
            console.error('The app will crash at startup without this patch.');
            console.error('The platform gate structure may have changed.');
            process.exit(1);
        }
        const orig = last[0];
        const guardVar = last[1];
        const patched = 'if(process.platform!=="linux"&&(' + guardVar +
            '==null?void 0:' + guardVar + '.status)!=="supported")';
        const absStart = winStart + last.index;
        code = code.substring(0, absStart) + patched +
            code.substring(absStart + orig.length);
        console.log('  Patched VM-supported gate to allow Linux');
        patchCount++;
    }
}

// ============================================================
// Patch 1b: VM-supported *evaluator* - report supported on Linux
// Patch 1 opens the startVM *execution* gate, but the refactored
// renderer (claude.ai web) gates the Cowork tab's *visibility* on the
// yukonSilver support *evaluator* ($oe -> q4r), a separate consumer.
// q4r() is the Windows capability probe (win32 VM bundle, MSIX via the
// install-type detector, Win10 build, Hyper-V HCS). On Linux it returns
// unsupportedCode:"msix_required" ("...installed with our modern
// installer"), which the web app maps to the grayed-out
// "Cowork requires a newer installation / Reinstall" tab (the daemon is
// up and healthy, but the UI never lets you reach it).
//
// Inject an early Linux return of {status:"supported"} at the top of
// q4r() so the evaluator reports supported. The downstream enterprise/
// user gates in $oe() (secureVmEnabled, coworkSurface.enabled,
// secureVmFeaturesEnabled — default-allow) still apply. Anchor on q4r's
// distinctive win32 + process.arch opening. Do NOT touch the install-
// type detector (see Patch 2's warning). Non-fatal: on a miss the tab
// stays grayed out but the app still runs, so warn rather than exit.
// ============================================================
{
    const evalRe =
        /(const [\w$]+="win32",([\w$]+)=process\.arch;if\(\2!=="x64"&&\2!=="arm64"\))/;
    if (/if\(process\.platform==="linux"\)return\{status:"supported"\};const [\w$]+="win32"/.test(code)) {
        console.log('  VM-supported evaluator Linux gate already' +
            ' applied (Patch 1b)');
    } else {
        const evalMatch = code.match(evalRe);
        if (!evalMatch) {
            console.log('  WARNING: could not find q4r support-evaluator' +
                ' anchor (win32/arch probe) — Cowork tab may stay grayed' +
                ' out on Linux (renderer reads the support evaluator)');
        } else {
            code = code.replace(evalRe,
                'if(process.platform==="linux")return{status:"supported"};$1');
            console.log('  Patched VM-supported evaluator to report' +
                ' supported on Linux');
            patchCount++;
        }
    }
}

// ============================================================
// Patch 1c: keep the VM-image download DISABLED on Linux
// Patch 1b flips the yukonSilver evaluator to "supported" so the
// renderer un-grays the Cowork tab. But the evaluator is ALSO read by
// the VM-image download drivers, which gate on
// yukonSilver.status==="supported". With 1b alone they re-arm and pull
// the multi-GB rootfs.vhdx/vmlinuz/initrd VM bundle that #337/a3190c3
// deliberately disabled — Linux runs cowork through the bwrap daemon,
// not a downloaded VM. Re-block the two download triggers on Linux so
// they behave as they did pre-1b (the old status="unsupported" path):
//   - download driver (startVM's download_and_sdk_prepare): returns !1
//   - warm prefetch (autoDownloadInBackground): early-returns
// startVM itself stays open (Patch 1), so the bwrap session is
// unaffected. Two sites: flag each; a non-fatal WARNING fires if either
// misses, so a half-applied build surfaces in CI's WARNING grep.
// ============================================================
{
    let dlDriverDone = false, warmDone = false;

    // Site A: download driver — (X==null?void 0:X.status)!=="supported"?!1:
    // The unique "[downloadVM] Download already in progress" log lives in
    // the same function, confirming this is the VM-image driver gate.
    const dlGateRe =
        /(\([\w$]+==null\?void 0:[\w$]+\.status\)!=="supported")\?!1:/;
    if (/process\.platform==="linux"\|\|\([\w$]+==null\?void 0:[\w$]+\.status\)!=="supported"\)\?!1:/.test(code)) {
        console.log('  VM-download Linux block already applied (Patch 1c-A)');
        dlDriverDone = true;
    } else if (dlGateRe.test(code) &&
        code.includes('[downloadVM] Download already in progress')) {
        code = code.replace(dlGateRe,
            '(process.platform==="linux"||$1)?!1:');
        console.log('  Patched VM-download driver to skip on Linux');
        dlDriverDone = true;
        patchCount++;
    }

    // Site B: warm prefetch — if(!X||X.status!=="supported"){await Y([]);return}
    const warmGateRe =
        /(if\()(![\w$]+\|\|[\w$]+\.status!=="supported")(\)\{await [\w$]+\(\[\]\);return\})/;
    if (/if\(process\.platform==="linux"\|\|![\w$]+\|\|[\w$]+\.status!=="supported"\)\{await [\w$]+\(\[\]\);return\}/.test(code)) {
        console.log('  Warm-download Linux block already applied (Patch 1c-B)');
        warmDone = true;
    } else if (warmGateRe.test(code)) {
        code = code.replace(warmGateRe,
            '$1process.platform==="linux"||$2$3');
        console.log('  Patched warm prefetch to skip on Linux');
        warmDone = true;
        patchCount++;
    }

    if (!dlDriverDone || !warmDone) {
        console.log('  WARNING: VM-download block partial — driver=' +
            dlDriverDone + ' warm=' + warmDone + '; Linux may re-arm the' +
            ' rootfs.vhdx download (#337) now that the evaluator reports' +
            ' supported (Patch 1b)');
    }
}

// ============================================================
// Patch 2: Module loading - use TypeScript VM client on Linux
// Anchor: unique string "vmClient (TypeScript)"
// Upstream 1.13576+ gates the vmClient module load behind Rl()
// (the MSIX/install-type detector) inside YBt():
//   async function YBt(){return Rl()?QL||QrA||(...,"vmClient
//     (TypeScript)"...QL={vm:hji}...):null}
// Both the log line and the {vm:...} assignment now live in this
// one Rl()?...:null expression, so widening the gate covers the
// old Patch 2a + 2b at once. Do NOT patch the gate fn itself — it
// also drives the isMsix install-type detection and would mis-flag
// Linux as an MSIX install.
// ============================================================
{
    const vmAnchor = '"vmClient (TypeScript)"';
    const vmIdx = code.indexOf(vmAnchor);
    const winStart = Math.max(0, vmIdx - 400);
    if (vmIdx === -1) {
        console.log('  WARNING: vmClient (TypeScript) anchor not found' +
            ' — Cowork module load gate not patched');
    } else if (/\([\w$]+\(\)\|\|process\.platform==="linux"\)\?/.test(
        code.substring(winStart, vmIdx))) {
        console.log('  vmClient Linux load gate already applied (Patch 2)');
    } else {
        // Find the `return FN()?` gate immediately before the log
        // string (scoped so the install-type `Rl()?"msix":...` ternary
        // isn't touched). FN is the minified isMsix detector and
        // changes between releases, so capture it dynamically.
        const region = code.substring(winStart, vmIdx);
        const gateRe = /return ([\w$]+)\(\)\?/g;
        let m, last = null;
        while ((m = gateRe.exec(region)) !== null) last = m;
        if (!last) {
            console.log('  WARNING: could not find `return FN()?` gate' +
                ' before vmClient log — module load not patched');
        } else {
            const fnName = last[1];
            const absStart = winStart + last.index;
            const orig = 'return ' + fnName + '()?';
            const patched =
                'return (' + fnName + '()||process.platform==="linux")?';
            code = code.substring(0, absStart) + patched +
                code.substring(absStart + orig.length);
            console.log('  Patched vmClient module load gate for Linux' +
                ' (gate fn: ' + fnName + ')');
            patchCount++;
        }
    }
}

// ============================================================
// Patch 3: Socket path - use Unix domain socket on Linux
// Anchor: unique string "cowork-vm-service" in pipe path
// ============================================================
const pipeMatch = code.match(/([\w$]+)(\s*=\s*)"([^"]*\\\\[^"]*cowork-vm-service[^"]*)"/);
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
    const statusRe = /getDownloadStatus\(\)\{return\s+([\w$]+\(\)\?([\w$]+)\.Downloading:[\w$]+\(\)\?\2\.Ready:\2\.NotDownloaded)\}/;
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
    if (/process\.platform==="linux"&&[\w$]+\.code==="ECONNREFUSED"/.test(code)) {
        console.log('  ENOENT/ECONNREFUSED expansion already applied');
    } else {
        const searchStart = Math.max(0, serviceErrorIdx - 300);
        const beforeRegion = code.substring(searchStart, serviceErrorIdx);
        const enoentRe = /([\w$]+)\.code\s*===\s*"ENOENT"/g;
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
    }

    // Step 2: Inject auto-launch before the retry delay
    if (code.includes('cowork-autolaunch')) {
        console.log('  Service daemon auto-launch already applied');
    } else {
        // Re-find serviceErrorStr since indices shifted after step 1
        const newServiceErrorIdx = code.lastIndexOf(serviceErrorStr);
        const searchEnd = Math.min(code.length, newServiceErrorIdx + 300);
        const searchRegion = code.substring(newServiceErrorIdx, searchEnd);
        // Upstream 1.13576+ replaced the inline retry delay
        // `await new Promise(r=>setTimeout(r,N))` with a helper call
        // `await dn(Eji)`. Match the single-arg awaited delay call
        // (two-arg awaits like `await Cji(A,e)` won't match).
        const retryMatch = searchRegion.match(
            /await [\w$]+\([\w$]+\)/
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
            const funcNameRe = /async function ([$\w]+)\s*\(\s*[$\w]+\s*,\s*[$\w]+\s*\)\s*\{[\s\S]*?for\s*\(\s*let/g;
            let funcMatch;
            let retryFuncName = null;
            while ((funcMatch = funcNameRe.exec(funcRegion)) !== null) {
                retryFuncName = funcMatch[1];
            }
            const spawnGuard = retryFuncName
                ? retryFuncName + '._lastSpawn'
                : 'globalThis._lastSpawn';
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
    }
} else {
    console.log('  WARNING: Could not find VM service error string for auto-launch');
}

// ============================================================
// Patch 6b: Extend auto-reinstall delete list (issue #408)
// Anchor: const NAME=["rootfs.img",...] — the module-level array
// driving the reinstall-files cleanup in _ue()/deleteVMBundle().
//
// NOTE (1.13576+/yukonSilver): rootfs.img now appears only in
// object form ([{name:"rootfs.img",...}]); the string-array anchor
// is gone, so this WARNs and is a safe no-op on the current bundle
// (the Linux VM-download path is disabled by Patch 4 anyway). It
// auto-reactivates if upstream restores the string array.
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
    const reinstallArrRe = /const ([\w$]+)=\[("rootfs\.img"[^\]]*)\];/;
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
//
// NOTE (1.13576+/yukonSilver): the mkdtemp(os.tmpdir(),"wvm-")
// shape is gone (the temp constant is now ".wvm-tmp-"), so this
// WARNs and is a safe no-op — the Linux VM-download path that
// would hit /tmp ENOSPC is disabled by Patch 4. Re-derive if the
// rootfs-download path is ever re-enabled on Linux.
// ============================================================
{
    // Find: MKDTEMP(PATH.join(OS.tmpdir(), "wvm-"))
    // The bundle dir var is used in mkdir(VAR, ...) just before
    const mkdtempRe = /([\w$]+)\.mkdtemp\(\s*([\w$]+)\.join\(\s*([\w$]+)\.tmpdir\(\)\s*,\s*"wvm-"\s*\)\s*\)/;
    const mkdtempMatch = code.match(mkdtempRe);
    if (mkdtempMatch) {
        const [fullMatch, fsVar, pathVar, osVar] = mkdtempMatch;
        // Find the bundle dir variable: mkdir(VAR, { recursive before wvm-
        const mkdtempIdx = code.indexOf(fullMatch);
        const searchStart = Math.max(0, mkdtempIdx - 2000);
        const before = code.substring(searchStart, mkdtempIdx);
        // Look for: mkdir(VARNAME, { recursive
        const mkdirRe = /([\w$]+)\.mkdir\(\s*([\w$]+)\s*,\s*\{\s*recursive/g;
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
    // Idempotency: key on the fork's OWN injected log ("…to bundle
    // (Linux)"), NOT the generic "[VM:start] Copying smol-bin" string
    // — upstream now ships its own (win32-gated) smol-bin copy that
    // emits the latter, which would falsely report "already present".
    if (code.includes('smol-bin.${_la}.vhdx to bundle (Linux)')) {
        console.log('  Linux smol-bin copy block already present');
    } else {
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
}

// ============================================================
// Patch 10: Register quit handler for cowork daemon cleanup
// The upstream vm-shutdown handler uses a Swift addon unavailable
// on Linux. Register our own to SIGTERM the daemon on app quit.
// ============================================================
{
    if (code.includes('cowork-linux-daemon-shutdown')) {
        console.log('  Linux cowork daemon quit handler already registered');
    } else {
        const quitFnRe = /registerQuitHandler:\s*([\w$]+)/;
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
		# Fail loudly on npm install failure rather than warn-and-continue.
		# The previous behavior silently dropped pty_src_dir, skipped the
		# entire copy block, and shipped the upstream Windows node-pty
		# binaries (the #401 failure mode). check_dependencies should now
		# install gcc/g++/make/python3 before we get here, so this branch
		# is the last line of defense for build-tool gaps that auto-install
		# couldn't fix (unknown distro, broken package mirror, etc.).
		if ! npm install node-pty 2>&1; then
			echo "Error: 'npm install node-pty' failed." >&2
			echo 'node-pty has a native module compiled via node-gyp;' >&2
			echo 'this usually means the build environment lacks a C/C++' >&2
			echo 'compiler, make, or python3.' >&2
			echo '' >&2
			echo 'Install build tools and re-run:' >&2
			echo '  Debian/Ubuntu: sudo apt install build-essential python3' >&2
			echo '  Fedora/RHEL:   sudo dnf install gcc gcc-c++ make python3' >&2
			cd "$project_root" || exit 1
			exit 1
		fi
		echo 'node-pty installed successfully'
		pty_src_dir="$node_pty_build_dir/node_modules/node-pty"
	fi

	if [[ -n $pty_src_dir && -d $pty_src_dir ]]; then
		echo 'Copying node-pty JavaScript files into app.asar.contents...'
		# Wipe the upstream-extracted node-pty before staging the Linux
		# build. The Windows installer's app.asar ships node-pty with
		# Windows binaries (winpty.dll, winpty-agent.exe, Windows
		# build/Release/*.node files). `cp -r $pty_src_dir/build` only
		# overwrites same-named files; orphan Windows binaries persist
		# inside the asar, surface as PE32+ when users inspect with
		# `asar list`, and pollute /tmp via Electron's lazy-extract on
		# any spurious require() (#401).
		rm -rf "$app_staging_dir/app.asar.contents/node_modules/node-pty"
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
