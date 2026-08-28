"""
DEP DLM GitOps Deployment View — Staging (GCP)

Only the data-orchestration engine (Rucio + FTS) stays in-cluster on GKE
Autopilot; secrets (Secret Manager), DB (Cloud SQL), IdP (external AAI
federation hub) and storage RSEs are all external — mirrors staging.py's
generic external-storage pattern, with GCP-specific managed services in
place of the generic placeholders. Structurally identical to production
by design.

Public ingress is the GKE Gateway API (gatewayClassName:
gke-l7-global-external-managed), NOT a plain k8s Ingress — that
gatewayClassName is what actually reconciles into a real GCP global
external Application Load Balancer (forwarding rule, target proxy,
backend services) holding the reserved static IP (gateway_static_ip).
Both rucio.dep-dlm-staging.example.com and fts.dep-dlm-staging.example.com
route through the same Gateway/HTTPRoute object via Host-header matching.

validation-storage is a testbed-owned exception to "storage is generic/
external": a single GCE VM (Container-Optimized OS, NOT GKE — see
modules/validation-storage) running XRootD (xrd3/xrd4) + Teapot/WebDAV
(teapot1/teapot2) via docker compose, reachable on its own public IP
through a firewall rule scoped to exactly those four ports. It's
registered as real Rucio RSEs (XRD3/XRD4/TEAPOT1/TEAPOT2 — see
shared/scripts/init-testbed.sh's configure_validation_storage_rses(),
no EXT_ prefix) so FTS exercises a genuine external network path — same
role as the generic Source/Destination RSEs, just with real
infrastructure instead of a placeholder.

Resolved via a private Cloud DNS zone (dep-dlm-staging-internal, zone
dep-dlm-staging.example.com.) shared with rucio/fts's own public
hostnames, rather than addressed by raw IP. This is load-bearing, not
cosmetic: FTS's actual transfer engine (the gfal2/davix client
performing the real davs:// TPC pull) does not consult the same
resolver path a per-pod /etc/hosts entry reaches, so DNS-record-less
IP addressing left every real transfer failing with UnknownHostException
even though diagnostic tools (curl, xrdfs, a plain Python `requests`
call) resolved the hostname fine. The managed zone is created once,
shared, at the environment level (environments/staging/main.tf);
validation-storage's own module only owns the A record pointing at its
reserved static IP, keeping the record's lifecycle tied to the VM it
describes.

The VM also trusts the same CA chain (rucio_ca.pem plus the two
grid-security hashes 5fca1cb1.*/b96dc756.*) pulled from the identical
Secret Manager "certs" secret every other RSE/FTS endpoint already
uses — no second trust root to manage.

Regenerate: python3 staging_gcp.py  (writes generated/staging-gcp.png)
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.gcp.compute import GKE, ComputeEngine
from diagrams.gcp.database import SQL
from diagrams.gcp.network import LoadBalancing, DNS
from diagrams.gcp.security import SecretManager, Iam
from diagrams.k8s.compute import Deployment
from diagrams.k8s.network import Ingress
from diagrams.onprem.gitops import Argocd
from diagrams.generic.network import Firewall
from diagrams.generic.storage import Storage

graph_attr = {
    "fontsize": "22",
    "bgcolor": "white",
    "pad": "0.6",
    "splines": "ortho",
    "nodesep": "0.7",
    "ranksep": "0.9",
}
node_attr = {"fontsize": "11"}
cluster_attr = {"margin": "30"}

with Diagram(
    "DEP DLM — Staging (GCP, storage external)",
    filename="generated/staging-gcp",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr,
):
    gitops = Argocd("GitOps engine\n(Argo CD or Flux)")

    idp_ext = Firewall("External AAI\nfederation hub\n(EGI / LS AAI)")
    source_rses = Storage("Source RSEs\n(data holdings,\ndata spaces)")
    dest_rses = Storage("Destination RSEs\n(compute centres)")

    with Cluster("GCP Project: dep-dlm-staging"):
        sm = SecretManager(
            "Secret Manager\n(dep-dlm-staging secrets\n+ certs, incl. shared CA chain)"
        )
        db = SQL("Cloud SQL\nfor PostgreSQL\n(rucio + fts metadata)")
        wif = Iam("Workload Identity\nFederation")
        glb = LoadBalancing(
            "Global External ALB\n(provisioned by GKE Gateway,\n"
            "static IP: gateway_static_ip)"
        )
        dns = DNS(
            "Cloud DNS\n(private zone:\ndep-dlm-staging.example.com,\n"
            "shared across rucio/fts/\nvalidation-storage hostnames)"
        )

        with Cluster("GKE Autopilot Cluster: dep-dlm-staging-gke"):
            gke = GKE("GKE Autopilot\n(managed control plane)")

            with Cluster("k8s namespace: dep-dlm-staging", graph_attr=cluster_attr):
                gateway = Ingress(
                    "Gateway API\n(Gateway + HTTPRoute,\n"
                    "gatewayClassName:\ngke-l7-global-external-managed)"
                )
                eso = Deployment("External Secrets\nOperator")
                rucio_server = Deployment("Rucio Server")
                rucio_daemons = Deployment("Rucio Daemons")
                fts = Deployment("FTS3")

        with Cluster(
            "GCE VM: dep-dlm-staging-validation-storage\n(public IP, not GKE)",
            graph_attr=cluster_attr,
        ):
            valstorage_fw = Firewall(
                "Firewall rule\n(0.0.0.0/0 :1094-1095,\n8081-8082)"
            )
            valstorage_vm = ComputeEngine(
                "Container-Optimized OS\ndocker compose:\n"
                "xrd3/xrd4 (XRootD)\nteapot1/teapot2 (WebDAV)"
            )
            valstorage_fw >> valstorage_vm

    gitops >> Edge(label="sync", style="dashed") >> rucio_server

    (
        glb
        >> Edge(label="rucio.*.example.com\nfts.*.example.com\n(Host header)")
        >> gateway
    )
    gateway >> rucio_server
    gateway >> fts

    wif >> Edge(label="federated\ncredential", style="dotted") >> eso
    eso >> Edge() >> sm
    rucio_server >> Edge() >> db
    rucio_server >> Edge() >> idp_ext
    rucio_daemons >> Edge(label="submit") >> fts

    fts >> Edge() >> db
    fts >> Edge() >> source_rses
    fts >> Edge() >> dest_rses
    source_rses >> Edge() >> dest_rses

    # validation-storage: real external network path, registered as
    # XRD3/XRD4/TEAPOT1/TEAPOT2 (no EXT_ prefix) and paired with the
    # generic sandbox RSEs above (same role, real infra) — see
    # shared/scripts/init-testbed.sh's configure_validation_storage_rses().
    #
    # DNS resolution is load-bearing here, not decorative: FTS's real
    # transfer engine only resolves valstorage.dep-dlm-staging.example.com
    # via this Cloud DNS record (see module docstring above) — a
    # per-pod /etc/hosts entry alone was confirmed insufficient for the
    # actual davs:// TPC pull, even though it satisfied diagnostic tools.
    dns >> Edge(label="A record", style="dashed") >> valstorage_vm
    fts >> Edge() >> valstorage_vm
    sm >> Edge(label="certs +\nCA chain") >> valstorage_vm

    gke >> Edge(style="invis") >> sm
