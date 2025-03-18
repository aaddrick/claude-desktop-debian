# SPECIAL INSTRUCTIONS FOR RUNNING MCP ON LINUX

To add a layeer of protection run the claude-desktop sandboxed using the command:
```claude_sandbox.sh```

It uses `bwrap` (also used by flatpack) to sandbox the application.
When run without arguments it creates the default sandbox `~/sandboxes/claude-desktop` and installs all the necessary tools in it. 

First run might take some time. Subsequent runs are faster.

Upon entering the sandbox execute `claude-desktop &` to start the application.

To create additional sandboxes, or if you wish to start multiple instances run the script with a name of the sandbox as an argument, e.g.:

`./claude_sandbox.sh sandbox1`

# Missing DISPLAY variable

Most MCP servers should run on Linux just fine, however there are some caveats like the lack of DISPLAY env variable that makes GUI based MCPs, like the browser based one, not work.

To address this, we have to manually add the DISPLAY env variable to the MCP server configuration, which on Linux resides in `~/.config/Claude/claude_desktop_config.json"`.
For example to run the Playwright MCP server, you would add the following configuration to the file:

```json
{
  "mcpServers": {
    "@executeautomation-playwright-mcp-server": {
      "command": "npx",
      "args": [
        "-y",
        "@executeautomation/playwright-mcp-server"
      ],
      "env": {
        "DISPLAY": ":0"
      }
    }
  }
}
```


# Creating a custom MCP server

To creating custom MCP tollow these steps:

```bash
mkdir my-mcp-server
cd my-mcp-server
uv init
# clone the modified mcp-python-sdk-linux
git clone https://github.com/emsi/mcp-python-sdk-linux
# add the linux mcp python-sdk to the project
uv add "./mcp-python-sdk-linux[cli]"

# Now create your custom mpc server in server.py file or copy one of the examples from the mcp-python-sdk-linux README.md

# install the server in claude-desktop app
uv run mcp install server.py
```

This will add the custom server to the claude-desktop app and you can now interact with it fromt he Claude Desktop app.


# Auto accepting tools

*Based on the : https://www.reddit.com/r/ClaudeAI/comments/1h9harx/auto_approve_mcp_tool_calls/*

To automatically accept all or selected tools follow this steps:

1. Enable debug tools:
```echo '{"allowDevTools": true}' > ~/.config/Claude/developer_settings.json```
1. Open the Claude Desktop App
1. Hit Ctrl + Shift + Alt + I
1. Two dev tool windows will open, you want the one starting with https://claude.ai in the window title.
1. Open the "Sources" tab in the dev tools window.
1. Open the "Snippets" tab
1. Click on "New snippet", name it `auto_approve.js`
1. Copy the content of `claude_mcp_auto_approve.js` in this directory to clipboard.
1. Paste the code into the snippet.
1. For sanboxed use all tools are accepted (empty trustedTools list)!
1. If you will, adjust the code to contain the tools you want to auto approve in the array.
1. Now you can run the script by right clicking on hit and clicking "Run".
1. You have to run the snippet after each claude-desktop restart.
