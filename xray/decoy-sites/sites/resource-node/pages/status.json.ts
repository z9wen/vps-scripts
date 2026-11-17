// /status.json: the node's parameters for monitoring, as edge nodes expose.
// The __KEY__ placeholders are filled in by the installer like the page's.
export function GET() {
  const status = {
    node: "__NODE__",
    status: "ok",
    service: "__SERVICE_ID__",
    region: "__COUNTRY__",
    pop: "__POP__",
    origin: "__ORIGIN__",
    software: "edge-node/__VERSION__",
    updated: "__TODAY__T04:00:00Z",
  };
  return new Response(JSON.stringify(status, null, 2), {
    headers: { "Content-Type": "application/json" },
  });
}
