// Your table's own endpoints. Claude Code can add to this file.
//
// The site calls this for every request that isn't a save (/api/save/...).
// Return true if you've answered the request, false to let the site carry on
// and serve files from site/. The site reloads within a second or two when
// this file changes, and a mistake here only switches these endpoints off.
//
// `tools` has: pathname, config (ROOT, WORKSHOP_FILE, SAVED_DIR and so on),
// sendJson(res, status, value), readBody(req, limit), writeFileAtomic(file, text),
// sameOrigin(req) (true if a request comes from this site's own pages).
// Anything that changes data must check tools.sameOrigin(req) first and
// answer 403 if it's false: it stops other tables' pages saving here.
//
// Example:
//   if (tools.pathname === "/api/hello" && req.method === "GET") {
//     tools.sendJson(res, 200, { hello: "world" });
//     return true;
//   }

module.exports = async function teamRoutes(req, res, tools) {
  return false;
};
