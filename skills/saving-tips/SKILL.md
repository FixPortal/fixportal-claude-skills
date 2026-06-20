---
name: saving-tips
description: Use when the user requests to save a tip, advice, command, or explanation to their Obsidian "Tips & Tricks" log (e.g., when they say "save that to tips" or "add to tips and tricks").
---

# Saving Tips

## Overview
Save useful explanations, commands, or workflow tips directly into a centralized "Tips & Tricks" note in your Obsidian Vault, organized by the active agent name.

## Configuration
*   **Obsidian Vault Root:** `<vault>` (Configure this to point to your local vault directory)
*   **Note Filename:** `Tips & Tricks.md`
*   Tips are organized in a **top-level per-agent folder** (e.g. `<vault>/Claude/`, `<vault>/Antigravity/`). Do **not** nest under a project folder such as `Acme`.

## Procedure

### 1. Identify the Active Agent
Determine the active agent name (e.g. `Antigravity`, `Claude`, `Codex`) from your system prompt.
If multiple agent names match, list the candidates and ask the user to confirm which one before proceeding.

### 2. Locate or Create the Target File
*   Construct the target path: `<vault>/<AgentName>/Tips & Tricks.md`
*   If the agent directory does not exist, create it.
*   If `Tips & Tricks.md` does not exist, create it with the header:
    ```markdown
    # <AgentName> Tips & Tricks
    
    A living document of persisted tips, tricks, and useful explanations.
    
    ---
    ```

### 3. Format and Append the Tip
Append the new tip to the file. Format it as follows:
```markdown
## <Brief Title or Topic>
*Saved on: <YYYY-MM-DD>*

<Content of the explanation or tip>

---
```

### 4. Confirm to User
Confirm to the user that the tip has been appended, providing the path to the file. Substitute the actual agent name detected in §1 into both the vault path and the URL — for example, if the agent is `Claude`, the link is:
[Tips & Tricks.md](file:///<vault>/Claude/Tips%20&%20Tricks.md)

## Common Mistakes
*   **Saving to workspace root:** Do not create a `tips.md` in the current coding directory.
*   **Formatting errors:** Ensure you wrap the Obsidian file links correctly in the output using forward slashes.
