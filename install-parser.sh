#!/bin/bash
# File: install-parser.sh
# Purpose: Build and install the ollama-cmd-parser

set -e

PARSER_NAME="ollama-cmd-parser"
INSTALL_DIR="/usr/local/bin"
BUILD_DIR=$(mktemp -d)
PARSER_VERSION="1.1.0"

echo "=== Installing ollama-cmd-parser v${PARSER_VERSION} ==="

# Cleanup on exit
trap "rm -rf $BUILD_DIR" EXIT

# Check if Go is available
if ! command -v go >/dev/null 2>&1; then
    echo "Error: Go is required but not installed"
    echo "Install with: apt install golang-go"
    exit 1
fi

echo "Go version: $(go version)"
echo "Build directory: $BUILD_DIR"

# Create the parser source
cat > "$BUILD_DIR/ollama-cmd-parser.go" << 'EOF'
package main

import (
    "encoding/json"
    "fmt"
    "go/ast"
    "go/parser"
    "go/token"
    "os"
    "regexp"
    "strconv"
    "strings"
)

const VERSION = "1.1.0"

// CommandDef represents a parsed cobra command definition
type CommandDef struct {
    Usage       string      `json:"usage"`
    Aliases     []string    `json:"aliases,omitempty"`
    ArgsRule    string      `json:"args_rule,omitempty"`
    MinArgs     int         `json:"min_args"`
    MaxArgs     int         `json:"max_args"`
    Flags       []FlagDef   `json:"flags"`
    ShortDesc   string      `json:"short_desc,omitempty"`
    Constraints *Constraints `json:"constraints,omitempty"`
}

// FlagDef represents a command flag
type FlagDef struct {
    Name         string `json:"name"`
    Short        string `json:"short,omitempty"`
    Type         string `json:"type"`
    DefaultValue string `json:"default_value,omitempty"`
    Description  string `json:"description,omitempty"`
}

// Constraints represents flag constraints for a command
type Constraints struct {
    MutuallyExclusive [][]string `json:"mutually_exclusive,omitempty"`
}

// ParsedCommands represents the complete parsed command structure
type ParsedCommands struct {
    Version     string                `json:"version"`
    ParserInfo  ParserInfo            `json:"parser_info"`
    Commands    map[string]CommandDef `json:"commands"`
}

// ParserInfo contains metadata about the parser
type ParserInfo struct {
    Version   string `json:"version"`
    ParsedAt  string `json:"parsed_at,omitempty"`
    SourceURL string `json:"source_url,omitempty"`
}

func main() {
    if len(os.Args) < 2 {
    printUsage()
    os.Exit(1)
    }

    switch os.Args[1] {
    case "--version", "-v":
    fmt.Printf("ollama-cmd-parser version %s\n", VERSION)
    os.Exit(0)
    case "--help", "-h":
    printUsage()
    os.Exit(0)
    default:
    if len(os.Args) != 2 {
        printUsage()
        os.Exit(1)
    }
    }

    filename := os.Args[1]
    
    // Check if file exists
    if _, err := os.Stat(filename); os.IsNotExist(err) {
    fmt.Fprintf(os.Stderr, "Error: File '%s' does not exist\n", filename)
    os.Exit(1)
    }

    // Parse the Go source file
    fset := token.NewFileSet()
    node, err := parser.ParseFile(fset, filename, nil, parser.ParseComments)
    if err != nil {
    fmt.Fprintf(os.Stderr, "Error parsing file: %v\n", err)
    os.Exit(1)
    }

    // Extract command definitions
    commands := extractCommands(node)
    
    // Extract constraints from handler functions
    constraints := extractConstraints(node)
    
    // Merge constraints into commands
    for cmdName, cmdConstraints := range constraints {
    if cmd, exists := commands[cmdName]; exists {
        cmd.Constraints = cmdConstraints
        commands[cmdName] = cmd
    }
    }
    
    if len(commands) == 0 {
    fmt.Fprintf(os.Stderr, "Warning: No cobra commands found in %s\n", filename)
    }

    // Create output structure
    result := ParsedCommands{
    Version: "unknown", // Will be filled by caller if needed
    ParserInfo: ParserInfo{
        Version: VERSION,
    },
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

func printUsage() {
    fmt.Printf(`ollama-cmd-parser v%s - Parse Cobra command definitions from Go source

Usage:
  %s <cmd.go file>        Parse cobra commands from Go source file
  %s --version           Show version information  
  %s --help              Show this help message

Examples:
  %s cmd.go              Parse commands from cmd.go
  %s --version           Show parser version

Output:
  JSON structure containing parsed command definitions, arguments, flags, and constraints.

`, VERSION, os.Args[0], os.Args[0], os.Args[0], os.Args[0], os.Args[0])
}

// extractConstraints walks the AST to find handler functions and extract constraints
func extractConstraints(node *ast.File) map[string]*Constraints {
    constraints := make(map[string]*Constraints)
    
    // Walk the AST to find function declarations
    ast.Inspect(node, func(n ast.Node) bool {
    if fn, ok := n.(*ast.FuncDecl); ok {
        if fn.Name != nil && strings.HasSuffix(fn.Name.Name, "Handler") {
	// Extract command name from handler function name
	// ShowHandler -> show, CreateHandler -> create
	cmdName := strings.ToLower(strings.TrimSuffix(fn.Name.Name, "Handler"))
	
	// Extract constraints from function body
	if cmdConstraints := parseHandlerConstraints(fn); cmdConstraints != nil {
	    constraints[cmdName] = cmdConstraints
	}
        }
    }
    return true
    })
    
    return constraints
}

// parseHandlerConstraints extracts constraint information from handler function bodies
func parseHandlerConstraints(fn *ast.FuncDecl) *Constraints {
    if fn.Body == nil {
    return nil
    }
    
    constraints := &Constraints{}
    
    // Look for mutual exclusion patterns in the function body
    ast.Inspect(fn.Body, func(n ast.Node) bool {
    if ifStmt, ok := n.(*ast.IfStmt); ok {
        // Look for patterns like: if flagsSet > 1 { return errors.New("only one of...") }
        if mutuallyExclusive := extractMutualExclusionFromIf(ifStmt); len(mutuallyExclusive) > 0 {
	constraints.MutuallyExclusive = append(constraints.MutuallyExclusive, mutuallyExclusive)
        }
    }
    return true
    })
    
    if len(constraints.MutuallyExclusive) == 0 {
    return nil
    }
    
    return constraints
}

// extractMutualExclusionFromIf extracts mutually exclusive flags from if statements
func extractMutualExclusionFromIf(ifStmt *ast.IfStmt) []string {
    // Look for return statements in the if body that contain error messages about mutual exclusion
    var errorStrings []string
    
    ast.Inspect(ifStmt, func(n ast.Node) bool {
    if returnStmt, ok := n.(*ast.ReturnStmt); ok {
        for _, result := range returnStmt.Results {
	if callExpr, ok := result.(*ast.CallExpr); ok {
	    // Look for errors.New() calls
	    if isErrorsNew(callExpr) && len(callExpr.Args) > 0 {
	    if lit, ok := callExpr.Args[0].(*ast.BasicLit); ok && lit.Kind == token.STRING {
	        if errorMsg, err := strconv.Unquote(lit.Value); err == nil {
		errorStrings = append(errorStrings, errorMsg)
	        }
	    }
	    }
	}
        }
    }
    return true
    })
    
    // Parse flag names from error messages
    for _, errorMsg := range errorStrings {
    if flags := parseConstraintErrorMessage(errorMsg); len(flags) > 0 {
        return flags
    }
    }
    
    return nil
}

// isErrorsNew checks if a call expression is errors.New()
func isErrorsNew(callExpr *ast.CallExpr) bool {
    if sel, ok := callExpr.Fun.(*ast.SelectorExpr); ok {
    if ident, ok := sel.X.(*ast.Ident); ok {
        return ident.Name == "errors" && sel.Sel.Name == "New"
    }
    }
    return false
}

// parseConstraintErrorMessage extracts flag names from constraint error messages
func parseConstraintErrorMessage(errorMsg string) []string {
    // Pattern to match: "only one of '--license', '--modelfile', '--parameters', '--system', or '--template' can be specified"
    re := regexp.MustCompile(`only one of ((?:'--[^']+',?\s*(?:or\s+)?)+) can be specified`)
    matches := re.FindStringSubmatch(errorMsg)
    
    if len(matches) < 2 {
    return nil
    }
    
    flagsStr := matches[1]
    
    // Extract individual flag names
    flagRe := regexp.MustCompile(`'--([^']+)'`)
    flagMatches := flagRe.FindAllStringSubmatch(flagsStr, -1)
    
    var flags []string
    for _, match := range flagMatches {
    if len(match) >= 2 {
        flags = append(flags, match[1])
    }
    }
    
    return flags
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
	    // FIXED: Parse both constraint type and argument values
	    constraintType, args := parseArgsConstraint(kv.Value)
	    if constraintType != "" {
	    cmd.ArgsRule = constraintType
	    cmd.MinArgs, cmd.MaxArgs = parseArgsLimits(constraintType, args)
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

// FIXED: parseArgsConstraint extracts cobra args constraint and returns both type and arguments
func parseArgsConstraint(expr ast.Expr) (string, []int) {
    if call, ok := expr.(*ast.CallExpr); ok {
    if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
        if ident, ok := sel.X.(*ast.Ident); ok && ident.Name == "cobra" {
	constraintType := sel.Sel.Name
	
	// Extract numeric arguments from the function call
	var args []int
	for _, arg := range call.Args {
	    if lit, ok := arg.(*ast.BasicLit); ok && lit.Kind == token.INT {
	    if val, err := strconv.Atoi(lit.Value); err == nil {
	        args = append(args, val)
	    }
	    }
	}
	
	return constraintType, args
        }
    }
    }
    return "", nil
}

// FIXED: parseArgsLimits converts cobra constraint and actual args to min/max args
func parseArgsLimits(constraint string, args []int) (int, int) {
    switch constraint {
    case "NoArgs":
    return 0, 0
    case "ExactArgs":
    if len(args) > 0 {
        // Use the actual argument value: cobra.ExactArgs(2) -> (2, 2)
        return args[0], args[0]
    }
    // Fallback if no argument found (shouldn't happen in valid code)
    return 1, 1
    case "MinimumNArgs":
    if len(args) > 0 {
        // Use the actual argument value: cobra.MinimumNArgs(2) -> (2, -1)
        return args[0], -1
    }
    // Fallback if no argument found (shouldn't happen in valid code)
    return 1, -1
    case "MaximumNArgs":
    if len(args) > 0 {
        // Use the actual argument value: cobra.MaximumNArgs(3) -> (0, 3)
        return 0, args[0]
    }
    // Fallback if no argument found (shouldn't happen in valid code)
    return 0, 1
    case "RangeArgs":
    if len(args) >= 2 {
        // Use the actual argument values: cobra.RangeArgs(1, 3) -> (1, 3)
        return args[0], args[1]
    }
    // Fallback if insufficient arguments found (shouldn't happen in valid code)
    return 1, 2
    case "ArbitraryArgs":
    return 0, -1
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
    flag := &FlagDef{Type: flagType}

    // Handle different flag types and their argument patterns
    switch flagType {
    case "BoolP", "StringP", "IntP":
    // BoolP/StringP/IntP: name, shorthand, default, description
    if len(args) >= 1 {
        if lit, ok := args[0].(*ast.BasicLit); ok && lit.Kind == token.STRING {
	name, _ := strconv.Unquote(lit.Value)
	flag.Name = name
        }
    }
    if len(args) >= 2 {
        if lit, ok := args[1].(*ast.BasicLit); ok && lit.Kind == token.STRING {
	short, _ := strconv.Unquote(lit.Value)
	flag.Short = short
        }
    }
    if len(args) >= 3 {
        if lit, ok := args[2].(*ast.BasicLit); ok {
	if lit.Kind == token.STRING {
	    defaultVal, _ := strconv.Unquote(lit.Value)
	    flag.DefaultValue = defaultVal
	} else {
	    flag.DefaultValue = lit.Value
	}
        }
    }
    if len(args) >= 4 {
        if lit, ok := args[3].(*ast.BasicLit); ok && lit.Kind == token.STRING {
	desc, _ := strconv.Unquote(lit.Value)
	flag.Description = desc
        }
    }
    default:
    // Bool, String, Int: name, default, description
    if len(args) >= 1 {
        if lit, ok := args[0].(*ast.BasicLit); ok && lit.Kind == token.STRING {
	name, _ := strconv.Unquote(lit.Value)
	flag.Name = name
        }
    }
    if len(args) >= 2 {
        if lit, ok := args[1].(*ast.BasicLit); ok {
	if lit.Kind == token.STRING {
	    defaultVal, _ := strconv.Unquote(lit.Value)
	    flag.DefaultValue = defaultVal
	} else {
	    flag.DefaultValue = lit.Value
	}
        }
    }
    if len(args) >= 3 {
        if lit, ok := args[2].(*ast.BasicLit); ok && lit.Kind == token.STRING {
	desc, _ := strconv.Unquote(lit.Value)
	flag.Description = desc
        }
    }
    }

    // Only return flag if we got at least a name
    if flag.Name != "" {
    return flag
    }
    return nil
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
EOF

# Build the parser
echo "Building parser..."
cd "$BUILD_DIR"
go mod init ollama-cmd-parser
go build -o "$PARSER_NAME" ollama-cmd-parser.go

# Test the parser binary
echo "Testing parser..."
"$BUILD_DIR/$PARSER_NAME" --version

# Check if we can install (need sudo for /usr/local/bin)
if [[ ! -w "$INSTALL_DIR" ]]; then
    echo "Installing to $INSTALL_DIR (requires sudo)..."
    sudo cp "$BUILD_DIR/$PARSER_NAME" "$INSTALL_DIR/"
    sudo chmod +x "$INSTALL_DIR/$PARSER_NAME"
else
    echo "Installing to $INSTALL_DIR..."
    cp "$BUILD_DIR/$PARSER_NAME" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/$PARSER_NAME"
fi

# Verify installation
echo "Verifying installation..."
if command -v "$PARSER_NAME" >/dev/null 2>&1; then
    echo "✅ Parser installed successfully!"
    echo "Location: $(which $PARSER_NAME)"
    echo "Version: $($PARSER_NAME --version)"
else
    echo "❌ Installation failed - parser not found in PATH"
    exit 1
fi

echo ""
echo "=== Installation Complete ==="
echo "Usage:"
echo "  $PARSER_NAME --version"
echo "  $PARSER_NAME --help"
echo "  $PARSER_NAME cmd.go"
echo ""
echo "Next: Test with real ollama cmd.go file and clear completion cache"
