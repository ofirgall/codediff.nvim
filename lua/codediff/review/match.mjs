// Match repo paths against review group patterns with native JavaScript regexes,
// so .github/pr-groups.json behaves exactly as in the github-fast-pr extension.
//
// stdin:  { "groups": [["^server/", "\\.go$"], ...], "files": ["server/a.go", ...] }
// stdout: { "errors": [{ "group": 1, "pattern": "...", "message": "..." }],
//           "matches": { "server/a.go": [1, 3] } }
// Group indices are 1-based (Lua). Paths matching no group are left out.
// When "errors" is non-empty, "matches" is empty.

let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  input += chunk;
});
process.stdin.on("end", () => {
  const { groups, files } = JSON.parse(input);
  const errors = [];
  const compiled = groups.map((paths, gi) =>
    paths.map((p) => {
      try {
        return new RegExp(p);
      } catch (e) {
        errors.push({ group: gi + 1, pattern: p, message: e.message });
        return null;
      }
    }),
  );
  const matches = {};
  if (errors.length === 0) {
    for (const path of files) {
      const hit = [];
      compiled.forEach((res, gi) => {
        if (res.some((r) => r.test(path))) hit.push(gi + 1);
      });
      if (hit.length > 0) matches[path] = hit;
    }
  }
  process.stdout.write(JSON.stringify({ errors, matches }));
});
