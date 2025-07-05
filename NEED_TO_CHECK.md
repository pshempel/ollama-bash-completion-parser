**Good catch!** 🎯 You found a gap in the command discovery.

## 🔍 **The Issue:**

The `help` command is likely a **built-in Cobra feature** that's not explicitly defined in `cmd.go` like the other commands. Cobra automatically adds `help` functionality, so our AST parser might not be finding it.

## 🧪 **Let's Investigate:**

**Check if `help` is in the parsed JSON:**
```bash
jq '.commands | keys[]' ~/.cache/ollama-completion/commands_v0.9.5.json | grep help
```

**Test current behavior:**
```bash
export OLLAMA_COMPLETION_DEBUG=1
ollama help <TAB>
# See what the debug output shows
```

## 🔧 **Likely Solutions:**

### **Option 1: Parser Enhancement**
The parser might need to detect Cobra's built-in commands, not just explicitly defined ones.

### **Option 2: Completion Fallback** 
Add fallback logic for known Cobra built-ins:
```bash
# If help not in JSON, provide manual completion
if ! command_exists_in_json "help"; then
    echo "$(get_all_commands_from_json)"
fi
```

### **Option 3: Cobra Help Detection**
Look for patterns like `rootCmd.AddCommand()` calls that might include help.

## 🤔 **Questions:**

1. **Is `help` missing from the JSON entirely?**
2. **Does `ollama help <TAB>` show anything currently?**
3. **What other built-in commands might we be missing?**

This is exactly the kind of edge case that makes your **"no hardcoding"** principle challenging but valuable - we need to discover even Cobra's implicit features!

**Want to debug this together?** Let's see what the parser is missing.
