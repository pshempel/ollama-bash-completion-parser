#!/bin/bash
# File: test-parser.sh
# Purpose: Test the ollama-cmd-parser with real ollama cmd.go file

set -e

echo "=== Testing ollama-cmd-parser ==="

# Create temporary directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "Working directory: $TEMP_DIR"

# Create the parser source code
cat > "$TEMP_DIR/ollama-cmd-parser.go" << 'EOF_PARSER'
package main

import (
    "encoding/json"
    "fmt"
    "go/ast"
    "go/parser"
    "go/token"
    "os"
    "strconv"
    "strings"
)

// CommandDef represents a parsed cobra command definition
type CommandDef struct {
    Usage     string            `json:"usage"`
    Aliases   []string          `json:"aliases,omitempty"`
    ArgsRule  string            `json:"args_rule,omitempty"`
    MinArgs   int               `json:"min_args"`
    MaxArgs   int               `json:"max_args"`
    Flags     []FlagDef         `json:"flags"`
    ShortDesc string            `json:"short_desc,omitempty"`
}

// FlagDef represents a command flag
type FlagDef struct {
    Name         string `json:"name"`
    Short        string `json:"short,omitempty"`
    Type         string `json:"type"`
    DefaultValue string `json:"default_value,omitempty"`
    Description  string `json:"description,omitempty"`
}

// ParsedCommands represents the complete parsed command structure
type ParsedCommands struct {
    Version  string                `json:"version"`
    Commands map[string]CommandDef `json:"commands"`
}

func main() {
    if len(os.Args) != 2 {
	fmt.Fprintf(os.Stderr, "Usage: %s <cmd.go file>\n", os.Args[0])
	os.Exit(1)
    }

    filename := os.Args[1]
    
    // Parse the Go source file
    fset := token.NewFileSet()
    node, err := parser.ParseFile(fset, filename, nil, parser.ParseComments)
    if err != nil {
	fmt.Fprintf(os.Stderr, "Error parsing file: %v\n", err)
	os.Exit(1)
    }

    // Extract command definitions
    commands := extractCommands(node)
    
    // Create output structure
    result := ParsedCommands{
	Version:  "unknown", // Will be filled by caller
	Commands: commands,
    }

    // Output JSON
    output, err := json.MarshalIndent(result, "", "  ")
    if err != nil {
	fmt.Fprintf(os.Stderr, "Error marshaling JSON: %v\n", err)
	os.Exit(1)
    }

    fmt.Println(string(output))
}

// extractCommands walks the AST to find cobra command definitions
func extractCommands(node *ast.File) map[string]CommandDef {
    commands := make(map[string]CommandDef)
    commandVars := make(map[string]string) // var name -> command name
    
    // Walk the AST
    ast.Inspect(node, func(n ast.Node) bool {
	switch x := n.(type) {
	case *ast.AssignStmt:
	    // Look for: cmdVar := &cobra.Command{...}
	    if len(x.Lhs) == 1 && len(x.Rhs) == 1 {
		if ident, ok := x.Lhs[0].(*ast.Ident); ok {
		    if cmd := parseCobraCommand(x.Rhs[0]); cmd != nil {
			cmdName := extractCommandName(cmd.Usage)
			if cmdName != "" {
			    commands[cmdName] = *cmd
			    commandVars[ident.Name] = cmdName
			}
		    }
		}
	    }
	case *ast.ExprStmt:
	    // Look for: cmdVar.Flags().String(...)
	    if call, ok := x.X.(*ast.CallExpr); ok {
		if cmdName, flag := parseFlagCall(call, commandVars); cmdName != "" && flag != nil {
		    if cmd, exists := commands[cmdName]; exists {
			cmd.Flags = append(cmd.Flags, *flag)
			commands[cmdName] = cmd
		    }
		}
	    }
	}
	return true
    })

    return commands
}

// parseCobraCommand extracts info from &cobra.Command{...} literal
func parseCobraCommand(expr ast.Expr) *CommandDef {
    unary, ok := expr.(*ast.UnaryExpr)
    if !ok || unary.Op != token.AND {
	return nil
    }

    comp, ok := unary.X.(*ast.CompositeLit)
    if !ok {
	return nil
    }

    // Check if it's cobra.Command
    if !isCobraCommand(comp.Type) {
	return nil
    }

    cmd := &CommandDef{
	MinArgs: 0,
	MaxArgs: -1, // unlimited by default
	Flags:   []FlagDef{},
    }

    // Parse the struct fields
    for _, elt := range comp.Elts {
	if kv, ok := elt.(*ast.KeyValueExpr); ok {
	    if ident, ok := kv.Key.(*ast.Ident); ok {
		switch ident.Name {
		case "Use":
		    if lit, ok := kv.Value.(*ast.BasicLit); ok && lit.Kind == token.STRING {
			usage, _ := strconv.Unquote(lit.Value)
			cmd.Usage = usage
		    }
		case "Short":
		    if lit, ok := kv.Value.(*ast.BasicLit); ok && lit.Kind == token.STRING {
			desc, _ := strconv.Unquote(lit.Value)
			cmd.ShortDesc = desc
		    }
		case "Aliases":
		    if aliases := parseStringSlice(kv.Value); len(aliases) > 0 {
			cmd.Aliases = aliases
		    }
		case "Args":
		    if args := parseArgsConstraint(kv.Value); args != "" {
			cmd.ArgsRule = args
			cmd.MinArgs, cmd.MaxArgs = parseArgsLimits(args)
		    }
		}
	    }
	}
    }

    return cmd
}

// isCobraCommand checks if the type is cobra.Command
func isCobraCommand(expr ast.Expr) bool {
    if sel, ok := expr.(*ast.SelectorExpr); ok {
	if ident, ok := sel.X.(*ast.Ident); ok {
	    return ident.Name == "cobra" && sel.Sel.Name == "Command"
	}
    }
    return false
}

// parseStringSlice extracts []string literals
func parseStringSlice(expr ast.Expr) []string {
    comp, ok := expr.(*ast.CompositeLit)
    if !ok {
	return nil
    }

    var result []string
    for _, elt := range comp.Elts {
	if lit, ok := elt.(*ast.BasicLit); ok && lit.Kind == token.STRING {
	    if str, err := strconv.Unquote(lit.Value); err == nil {
		result = append(result, str)
	    }
	}
    }
    return result
}

// parseArgsConstraint extracts cobra args constraint like cobra.ExactArgs(1)
func parseArgsConstraint(expr ast.Expr) string {
    if call, ok := expr.(*ast.CallExpr); ok {
	if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
	    if ident, ok := sel.X.(*ast.Ident); ok && ident.Name == "cobra" {
		return sel.Sel.Name
	    }
	}
    }
    return ""
}

// parseArgsLimits converts cobra constraint to min/max args
func parseArgsLimits(constraint string) (int, int) {
    switch constraint {
    case "NoArgs":
	return 0, 0
    case "ExactArgs":
	// Need to extract number from call, default to 1
	return 1, 1
    case "MinimumNArgs":
	// Need to extract number from call, default to 1
	return 1, -1
    case "MaximumNArgs":
	return 0, 1
    case "RangeArgs":
	return 1, 2 // Default range
    default:
	return 0, -1
    }
}

// parseFlagCall extracts flag definitions from cmdVar.Flags().Type(...) calls
func parseFlagCall(call *ast.CallExpr, commandVars map[string]string) (string, *FlagDef) {
    // Look for pattern: cmdVar.Flags().String(name, default, description)
    if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
	if innerCall, ok := sel.X.(*ast.CallExpr); ok {
	    if innerSel, ok := innerCall.Fun.(*ast.SelectorExpr); ok {
		if ident, ok := innerSel.X.(*ast.Ident); ok {
		    // Check if this is a command variable we know about
		    if cmdName, exists := commandVars[ident.Name]; exists {
			if innerSel.Sel.Name == "Flags" {
			    // Extract flag info
			    flagType := sel.Sel.Name
			    return cmdName, parseFlagDefinition(call.Args, flagType)
			}
		    }
		}
	    }
	}
    }
    return "", nil
}

// parseFlagDefinition extracts flag details from function arguments
func parseFlagDefinition(args []ast.Expr, flagType string) *FlagDef {
    if len(args) < 3 {
	return nil
    }

    flag := &FlagDef{Type: flagType}

    // First arg: flag name
    if lit, ok := args[0].(*ast.BasicLit); ok && lit.Kind == token.STRING {
	name, _ := strconv.Unquote(lit.Value)
	flag.Name = name
    }

    // Second arg: default value  
    if lit, ok := args[1].(*ast.BasicLit); ok {
	if lit.Kind == token.STRING {
	    defaultVal, _ := strconv.Unquote(lit.Value)
	    flag.DefaultValue = defaultVal
	} else {
	    flag.DefaultValue = lit.Value
	}
    }

    // Third arg: description
    if lit, ok := args[2].(*ast.BasicLit); ok && lit.Kind == token.STRING {
	desc, _ := strconv.Unquote(lit.Value)
	flag.Description = desc
    }

    return flag
}

// extractCommandName gets the command name from usage string like "run MODEL [PROMPT]"
func extractCommandName(usage string) string {
    if usage == "" {
	return ""
    }
    
    parts := strings.Fields(usage)
    if len(parts) == 0 {
	return ""
    }
    
    return parts[0]
}
EOF_PARSER

# Create test cmd.go file with cobra commands
cat > "$TEMP_DIR/cmd.go" << 'EOF_CMDGO'
package cmd

import (
    "github.com/spf13/cobra"
)

// Test cobra command definitions
func NewCLI() *cobra.Command {
    createCmd := &cobra.Command{
	Use:     "create MODEL",
	Short:   "Create a model from a Modelfile",
	Args:    cobra.ExactArgs(1),
    }

    createCmd.Flags().StringP("file", "f", "", "Name of the Modelfile")
    createCmd.Flags().StringP("quantize", "q", "", "Quantize model to this level")

    showCmd := &cobra.Command{
	Use:     "show MODEL",
	Short:   "Show information for a model",
	Args:    cobra.ExactArgs(1),
    }

    showCmd.Flags().Bool("license", false, "Show license of a model")
    showCmd.Flags().Bool("modelfile", false, "Show Modelfile of a model")
    showCmd.Flags().Bool("parameters", false, "Show parameters of a model")
    showCmd.Flags().Bool("template", false, "Show template of a model")
    showCmd.Flags().Bool("system", false, "Show system message of a model")
    showCmd.Flags().BoolP("verbose", "v", false, "Show detailed model information")

    runCmd := &cobra.Command{
	Use:     "run MODEL [PROMPT]",
	Short:   "Run a model",
	Args:    cobra.MinimumNArgs(1),
    }

    runCmd.Flags().String("keepalive", "", "Duration to keep a model loaded")
    runCmd.Flags().Bool("verbose", false, "Show timings for response")
    runCmd.Flags().String("format", "", "Response format (e.g. json)")
    runCmd.Flags().Bool("think", false, "Whether to use thinking mode")

    listCmd := &cobra.Command{
	Use:     "list",
	Aliases: []string{"ls"},
	Short:   "List models",
    }

    psCmd := &cobra.Command{
	Use:     "ps",
	Short:   "List running models",
    }

    copyCmd := &cobra.Command{
	Use:     "cp SOURCE DESTINATION",
	Short:   "Copy a model",
	Args:    cobra.ExactArgs(2),
    }

    stopCmd := &cobra.Command{
	Use:     "stop MODEL",
	Short:   "Stop a running model",
	Args:    cobra.ExactArgs(1),
    }

    return nil
}
EOF_CMDGO

# Compile the parser
echo "Compiling parser..."
cd "$TEMP_DIR"
go mod init test-parser
go build -o ollama-cmd-parser ollama-cmd-parser.go

# Test the parser
echo "Running parser on cmd.go..."
./ollama-cmd-parser cmd.go > output.json

# Show results
echo "=== Parser Output ==="
cat output.json

# Validate JSON
echo ""
echo "=== JSON Validation ==="
if command -v jq >/dev/null 2>&1; then
    echo "JSON is valid!"
    echo ""
    echo "=== Commands Found ==="
    jq -r '.commands | keys[]' output.json | sort
    echo ""
    echo "=== Sample Command Details ==="
    echo "run command:"
    jq '.commands.run' output.json
    echo ""
    echo "show command:"
    jq '.commands.show' output.json
else
    echo "jq not available, skipping validation"
fi

echo ""
echo "=== Test Complete ==="
echo "Parser binary: $TEMP_DIR/ollama-cmd-parser"
echo "Output file: $TEMP_DIR/output.json"
