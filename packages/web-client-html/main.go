package main

import (
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"unicode/utf8"

	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"
)

// Nix sets an absolute path at build time; local builds use PATH.
var diffCommand = "diff"

var elementMetaCSP = regexp.MustCompile(`(?s)\n    <meta http-equiv="Content-Security-Policy" content=".*?\n    ">`)

// Parse only for inspection. Never serialize the tree or trim script text.
// Both inspection and hashing count every src-less script, including empty ones.
func inlineScripts(source string) ([]string, error) {
	if !utf8.ValidString(source) {
		return nil, fmt.Errorf("expected UTF-8 HTML")
	}
	document, err := html.Parse(strings.NewReader(source))
	if err != nil {
		return nil, err
	}
	var scripts []string
	var visit func(*html.Node)
	visit = func(node *html.Node) {
		if node.Type == html.ElementNode && node.DataAtom == atom.Script {
			for _, attr := range node.Attr {
				if attr.Namespace == "" && attr.Key == "src" {
					return
				}
			}
			var body strings.Builder
			for child := node.FirstChild; child != nil; child = child.NextSibling {
				if child.Type == html.TextNode {
					body.WriteString(child.Data)
				}
			}
			scripts = append(scripts, body.String())
			return
		}
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			visit(child)
		}
	}
	visit(document)
	return scripts, nil
}

func transform(client, relative, source, snippetDir string) (string, error) {
	var snippets []string
	if relative != "index.html" {
		snippets = []string{"global-equals.js", "promise-with-resolvers.js"}
	} else {
		switch client {
		case "sable":
			snippets = []string{"global-or.js", "sable-preload.js"}
		case "cinny":
			snippets = []string{"global-or.js"}
		case "element":
			if count := len(elementMetaCSP.FindAllStringIndex(source, -1)); count != 1 {
				return "", fmt.Errorf("expected exactly one upstream meta CSP, found %d", count)
			}
			source = elementMetaCSP.ReplaceAllString(source, "")
		}
	}
	for _, name := range snippets {
		body, err := os.ReadFile(filepath.Join(snippetDir, name))
		if err != nil {
			return "", err
		}
		old := "<script>" + string(body) + "</script>"
		if count := strings.Count(source, old); count != 1 {
			return "", fmt.Errorf("expected %s snippet exactly once, found %d", name, count)
		}
		source = strings.Replace(source, old, `<script src="/csp-inline/`+name+`"></script>`, 1)
	}
	scripts, err := inlineScripts(source)
	if err != nil {
		return "", err
	}
	if len(scripts) != 0 {
		return "", fmt.Errorf("%d unexternalized inline script(s) remain", len(scripts))
	}
	return source, nil
}

func processFile(client, root, snippetDir, diffDir, relative string) error {
	path := filepath.Join(root, relative)
	before, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	after, err := transform(client, relative, string(before), snippetDir)
	if err != nil {
		return err
	}
	// Feed the transformed text directly to diff; no intermediate HTML files.
	cmd := exec.Command(diffCommand, "-u", "--label", "before/"+relative, "--label", "after/"+relative, path, "-")
	cmd.Stdin = strings.NewReader(after)
	cmd.Stderr = os.Stderr
	diff, err := cmd.Output()
	if err != nil {
		// Exit 1 is an ordinary difference; all other failures must propagate.
		if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 1 {
			return fmt.Errorf("diff: %w", err)
		}
	}
	diffName := client + "-" + strings.ReplaceAll(relative, "/", "-") + ".diff"
	if err := os.WriteFile(filepath.Join(diffDir, diffName), diff, 0644); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(after), 0644)
}

func process(client, root, snippetDir, diffDir string) error {
	var callHTML string
	switch client {
	case "sable", "cinny":
		callHTML = "public/element-call/index.html"
	case "element":
		callHTML = "widgets/element-call/index.html"
	default:
		return fmt.Errorf("unknown web client: %s", client)
	}
	if err := os.MkdirAll(diffDir, 0755); err != nil {
		return err
	}
	for _, relative := range []string{"index.html", callHTML} {
		if err := processFile(client, root, snippetDir, diffDir, relative); err != nil {
			return fmt.Errorf("%s:%s: %w", client, relative, err)
		}
	}
	return nil
}

func hashes(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	scripts, err := inlineScripts(string(data))
	if err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	hashes := make([]string, 0, len(scripts))
	for _, body := range scripts {
		digest := sha256.Sum256([]byte(body))
		hashes = append(hashes, "'sha256-"+base64.StdEncoding.EncodeToString(digest[:])+"'")
	}
	_, err = fmt.Fprintln(os.Stdout, strings.Join(hashes, " "))
	return err
}

func run(args []string) error {
	if len(args) == 5 && args[0] == "process" {
		return process(args[1], args[2], args[3], args[4])
	}
	if len(args) == 2 && args[0] == "hashes" {
		return hashes(args[1])
	}
	return fmt.Errorf("usage: web-client-html process CLIENT ROOT SNIPPETS DIFF_DIR\n       web-client-html hashes FILE")
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "web-client-html:", err)
		os.Exit(1)
	}
}
