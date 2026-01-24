/**
 * Stub implementation of @ant/claude-swift for Linux
 *
 * On macOS, this module provides VM functionality for Cowork Mode using
 * Apple's Virtualization Framework. On Linux, we provide a stub that
 * simulates the VM lifecycle but runs Claude Code CLI directly on the host.
 *
 * STATUS: Partial implementation
 * - VM lifecycle simulation: WORKS
 * - Process spawning: WORKS
 * - Stdin communication: WORKS
 * - Stdout communication: DOES NOT WORK (events don't fire in Electron)
 *
 * The stdout issue blocks Cowork mode from being fully functional.
 * See: https://github.com/chukfinley/claude-desktop-linux/issues/1
 */

const EventEmitter = require("events");
const { spawn } = require("child_process");
const path = require("path");
const fs = require("fs");
const os = require("os");

const DEBUG = process.env.CLAUDE_LINUX_DEBUG === "1";

function log(...args) {
  if (DEBUG) console.log("[LinuxVM]", ...args);
}

class LinuxVMAddon extends EventEmitter {
  constructor() {
    super();
    this.vmProcess = null;
    this.vmRunning = false;
    this.guestConnected = false;
    this.processes = new Map();
    this.debugLogging = DEBUG;
    this.stdoutCallback = null;
    this.stderrCallback = null;
    this.exitCallback = null;
    this.errorCallback = null;

    log("Linux VM Addon initialized (stub)");
  }

  async startVM(bundlePath, ramSizeGB = 8) {
    log(`startVM: bundle=${bundlePath}, ram=${ramSizeGB}GB`);
    if (this.vmRunning) return;

    // Direct mode - no actual VM, run on host
    this.vmRunning = true;
    this.guestConnected = true;
    this.emit("guestConnectionChanged", true);
  }

  async stopVM() {
    log("stopVM");
    for (const [id, proc] of this.processes) {
      try { proc.kill("SIGTERM"); } catch (e) {}
    }
    this.processes.clear();
    this.vmRunning = false;
    this.guestConnected = false;
    this.emit("guestConnectionChanged", false);
  }

  isGuestConnected() { return this.guestConnected; }
  isRunning() { return this.vmRunning; }
  isProcessRunning(name) { return this.processes.size > 0; }
  isDebugLoggingEnabled() { return this.debugLogging; }
  getVmProcessId() { return this.vmProcess?.pid || process.pid; }

  async prepareForVM() { return { ready: true }; }

  // OAuth token management (stubs - not needed in direct mode)
  async addApprovedOauthToken(token) { return { success: true }; }
  async removeApprovedOauthToken(token) { return { success: true }; }
  async getApprovedOauthTokens() { return []; }

  // Mount path management (passthrough in direct mode)
  async mountPath(sessionId, hostPath, name, mode = "rw") {
    log(`mountPath: ${name} -> ${hostPath}`);
    return { success: true, guestPath: hostPath };
  }

  async unmountPath(sessionId, name) {
    return { success: true };
  }

  setEventCallbacks(stdoutCb, stderrCb, exitCb, errorCb) {
    this.stdoutCallback = stdoutCb;
    this.stderrCallback = stderrCb;
    this.exitCallback = exitCb;
    this.errorCallback = errorCb;
  }

  async spawn(sessionId, processName, command, args, cwd, envVars, mounts, isResume, allowedDomains, sharedCwd) {
    log(`spawn: ${processName}, command=${command}`);

    const homeDir = os.homedir();

    // Resolve working directory
    let workDir = cwd;
    if (sharedCwd) {
      workDir = path.join(homeDir, sharedCwd);
    } else if (cwd?.startsWith("/sessions/")) {
      workDir = homeDir;
    }

    if (!fs.existsSync(workDir)) {
      workDir = homeDir;
    }

    // Build mount path mapping for VM path translation
    const mountPathMap = {};
    if (mounts && typeof mounts === "object") {
      for (const [mountName, mountInfo] of Object.entries(mounts)) {
        if (mountInfo?.path) {
          const vmPath = `/sessions/${processName}/mnt/${mountName}`;
          const realPath = path.join(homeDir, mountInfo.path);
          mountPathMap[vmPath] = realPath;
        }
      }
    }

    // Transform VM paths to real paths in arguments
    const transformPath = (arg) => {
      if (typeof arg !== "string") return arg;
      for (const [vmPath, realPath] of Object.entries(mountPathMap)) {
        if (arg === vmPath || arg.startsWith(vmPath + "/")) {
          return arg.replace(vmPath, realPath);
        }
      }
      return arg;
    };

    // Find command in PATH if not found at specified location
    let actualCommand = command;
    if (!fs.existsSync(command)) {
      const { execSync } = require("child_process");
      const basename = path.basename(command);
      try {
        actualCommand = execSync(`which ${basename}`, { encoding: "utf-8" }).trim();
        log(`Found ${basename} at: ${actualCommand}`);
      } catch {
        log(`Command not found: ${command}`);
        setTimeout(() => {
          if (this.stderrCallback) this.stderrCallback(sessionId, `Error: ${command} not found\n`);
          if (this.exitCallback) this.exitCallback(sessionId, 127, null);
        }, 100);
        return { pid: 0 };
      }
    }

    // Transform arguments and filter SDK MCP servers
    let spawnArgs = (args || []).map(transformPath);

    const mcpConfigIdx = spawnArgs.indexOf("--mcp-config");
    if (mcpConfigIdx !== -1 && mcpConfigIdx + 1 < spawnArgs.length) {
      try {
        const mcpConfig = JSON.parse(spawnArgs[mcpConfigIdx + 1]);
        if (mcpConfig.mcpServers) {
          // Filter out SDK-type MCP servers (they require VM communication)
          const filteredServers = {};
          for (const [name, config] of Object.entries(mcpConfig.mcpServers)) {
            if (config.type !== "sdk") {
              filteredServers[name] = config;
            } else {
              log(`Filtering SDK MCP server: ${name}`);
            }
          }
          mcpConfig.mcpServers = filteredServers;
          spawnArgs[mcpConfigIdx + 1] = JSON.stringify(mcpConfig);
        }
      } catch (e) {}
    }

    // Spawn the process
    const spawnEnv = {
      ...process.env,
      ...(envVars || {}),
      TERM: "xterm-256color",
    };

    const proc = spawn(actualCommand, spawnArgs, {
      cwd: workDir,
      env: spawnEnv,
      stdio: ["pipe", "pipe", "pipe"],
    });

    this.processes.set(sessionId, proc);
    log(`Spawned PID: ${proc.pid}`);

    const self = this;

    // Set up stdout/stderr handlers
    // NOTE: These events don't fire in Electron for unknown reasons
    // This is the main blocker for Cowork mode on Linux
    proc.stdout.on("data", (data) => {
      const str = data.toString();
      log(`stdout: ${str.length} bytes`);
      if (self.stdoutCallback) self.stdoutCallback(sessionId, str);
    });

    proc.stderr.on("data", (data) => {
      const str = data.toString();
      log(`stderr: ${str.length} bytes`);
      if (self.stderrCallback) self.stderrCallback(sessionId, str);
    });

    proc.on("exit", (code, signal) => {
      log(`exit: code=${code}, signal=${signal}`);
      self.processes.delete(sessionId);
      if (self.exitCallback) self.exitCallback(sessionId, code, signal);
    });

    proc.on("error", (err) => {
      log(`error: ${err.message}`);
      if (self.errorCallback) self.errorCallback(sessionId, err.message);
    });

    proc.id = sessionId;
    return proc;
  }

  async installSdk(subpath, version) {
    log(`installSdk: ${subpath}@${version}`);
    return { success: true };
  }

  async sendInput(sessionId, input) {
    return this.writeStdin(sessionId, input);
  }

  async writeStdin(sessionId, data) {
    const proc = this.processes.get(sessionId);
    if (!proc?.stdin) {
      return { success: false };
    }

    let dataStr = String(data);

    // Filter sdkMcpServers from init message - CLI hangs waiting for them
    try {
      const msg = JSON.parse(dataStr);
      if (msg.type === "control_request" && msg.request?.subtype === "initialize") {
        if (msg.request.sdkMcpServers) {
          log("Filtering sdkMcpServers from init message");
          delete msg.request.sdkMcpServers;
          dataStr = JSON.stringify(msg);
        }
      }
    } catch (e) {}

    // Ensure newline for stream-json format
    if (!dataStr.endsWith("\n")) {
      dataStr += "\n";
    }

    proc.stdin.write(dataStr);
    return { success: true };
  }

  async sendResize(sessionId, cols, rows) {
    return { success: true };
  }

  async killProcess(sessionId) {
    const proc = this.processes.get(sessionId);
    if (proc) {
      proc.kill("SIGTERM");
      this.processes.delete(sessionId);
      return { success: true };
    }
    return { success: false };
  }
}

// Create singleton and export
const addon = new LinuxVMAddon();
module.exports = addon;

// Attach additional properties expected by the app
addon.vm = addon;
addon.quickAccess = {};
addon.notifications = {};
addon.desktop = {};
addon.api = {};
addon.midnightOwl = {};
