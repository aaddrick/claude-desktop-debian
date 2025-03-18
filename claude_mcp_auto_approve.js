// Array of trusted tool names.
// If empty ALL tools are accepted!
const trustedTools = [
/*
    'list-allowed-directories',
    'list-denied-directories',
    'ls'
*/
];

// Cooldown tracking
let lastClickTime = 0;
const COOLDOWN_MS = 1000; // 1 second cooldown

const observer = new MutationObserver((mutations) => {
    // Check if we're still in cooldown
    const now = Date.now();
    if (now - lastClickTime < COOLDOWN_MS) {
        console.log('🕒 Still in cooldown period, skipping...');
        return;
    }

    console.log('🔍 Checking mutations...');
    
    const dialog = document.querySelector('[role="dialog"]');
    if (!dialog) return;

    const buttonWithDiv = dialog.querySelector('button div');
    if (!buttonWithDiv) return;

    const toolText = buttonWithDiv.textContent;
    if (!toolText) return;

    console.log('📝 Found tool request:', toolText);
    
    const toolName = toolText.match(/Run (\S+) from/)?.[1];
    if (!toolName) return;

    console.log('🛠️ Tool name:', toolName);
    
    if (trustedTools.length === 0 || trustedTools.includes(toolName)) {
        const allowButton = Array.from(dialog.querySelectorAll('button'))
            .find(button => button.textContent.includes('Allow for This Chat'));
        
        if (allowButton) {
            console.log('🚀 Auto-approving tool:', toolName);
            lastClickTime = now; // Set cooldown
            allowButton.click();
        }
    } else {
        console.log('❌ Tool not in trusted list:', toolName);
    }
});

// Start observing
console.log('👀 Starting observer for trusted tools:', trustedTools);
observer.observe(document.body, {
    childList: true,
    subtree: true
});
