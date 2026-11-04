package main

import (
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"unicode/utf8"

	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"
)

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

// Keep Element's HTML unchanged except for its deployment-specific meta CSP.
// The HTTP policy is supplied by Nginx.
func removeMetaCSP(path string) error {
	source, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if !utf8.Valid(source) {
		return fmt.Errorf("%s: expected UTF-8 HTML", path)
	}
	if count := len(elementMetaCSP.FindAllIndex(source, -1)); count != 1 {
		return fmt.Errorf("%s: expected exactly one upstream meta CSP, found %d", path, count)
	}
	return os.WriteFile(path, elementMetaCSP.ReplaceAll(source, nil), 0644)
}

// Hash a single document or every HTML file in a tree without rewriting scripts.
func scriptHashes(path string) ([]string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	files := []string{path}
	if info.IsDir() {
		files = nil
		if err := filepath.WalkDir(path, func(name string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if !entry.IsDir() && filepath.Ext(name) == ".html" {
				if !entry.Type().IsRegular() {
					return fmt.Errorf("%s: expected a regular HTML file", name)
				}
				files = append(files, name)
			}
			return nil
		}); err != nil {
			return nil, err
		}
		if len(files) == 0 {
			return nil, fmt.Errorf("%s: no HTML files found", path)
		}
	}

	unique := make(map[string]bool)
	for _, file := range files {
		data, err := os.ReadFile(file)
		if err != nil {
			return nil, err
		}
		scripts, err := inlineScripts(string(data))
		if err != nil {
			return nil, fmt.Errorf("%s: %w", file, err)
		}
		for _, body := range scripts {
			digest := sha256.Sum256([]byte(body))
			unique["'sha256-"+base64.StdEncoding.EncodeToString(digest[:])+"'"] = true
		}
	}
	hashes := make([]string, 0, len(unique))
	for hash := range unique {
		hashes = append(hashes, hash)
	}
	slices.Sort(hashes)
	return hashes, nil
}

func hashes(path string) error {
	hashes, err := scriptHashes(path)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintln(os.Stdout, strings.Join(hashes, " "))
	return err
}

func run(args []string) error {
	if len(args) == 2 && args[0] == "remove-meta-csp" {
		return removeMetaCSP(args[1])
	}
	if len(args) == 2 && args[0] == "hashes" {
		return hashes(args[1])
	}
	return fmt.Errorf("usage: web-client-html remove-meta-csp FILE\n       web-client-html hashes FILE_OR_DIRECTORY")
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "web-client-html:", err)
		os.Exit(1)
	}
}
