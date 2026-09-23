// Holds the Lagoon service port (3000) from the first second of boot and pipes
// it to the gateway on OPENCLAW_GATEWAY_PORT. Lagoon's liveness probe is a
// hardcoded TCP check on the service port with a 60s delay (build-deploy-tool
// template_podspec.go), and doctor migrations or a gateway validating a large
// session store can take longer than that to bind -- the kubelet then kills the
// container mid-boot, forever.
//
// Dial the pod IP, never loopback: the gateway treats loopback clients as local,
// which would hand that trust to proxied public traffic. The pod IP is inside
// gateway.trustedProxies, so the ingress X-Forwarded-For still applies.
// ponytail: TCP liveness now only proves this proxy is up; a crashed gateway still
// restarts the container (it is the entrypoint's exec'd process).
const net = require('net');
const os = require('os');

const upstreamPort = Number(process.env.OPENCLAW_GATEWAY_PORT);
const podIp = Object.values(os.networkInterfaces()).flat()
  .find((i) => !i.internal && i.family === 'IPv4')?.address;
if (!podIp) {
  console.error('[gateway-port-proxy] no pod IPv4 address found; not starting');
  process.exit(1);
}

net.createServer((client) => {
  const upstream = net.connect(upstreamPort, podIp);
  client.on('error', () => upstream.destroy());
  upstream.on('error', () => client.destroy());
  client.pipe(upstream).pipe(client);
}).listen(3000, () => {
  console.error(`[gateway-port-proxy] :3000 -> ${podIp}:${upstreamPort}`);
});
