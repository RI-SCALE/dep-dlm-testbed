"""
DEP DLM GitOps Deployment View — Staging (GCP)
Only the data-orchestration engine (Rucio + FTS) stays in-cluster on GKE
Autopilot; secrets (Secret Manager), DB (Cloud SQL), IdP (external AAI
federation hub) and storage RSEs are all external — mirrors staging.py's
generic external-storage pattern, with GCP-specific managed services in
place of the generic placeholders. Structurally identical to production
by design.
Regenerate: python3 staging_gcp.py  (writes generated/staging-gcp.png)
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.gcp.compute import GKE
from diagrams.gcp.database import SQL
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
        sm = SecretManager("Secret Manager\n(dep-dlm-staging secrets)")
        db = SQL("Cloud SQL\nfor PostgreSQL\n(rucio + fts metadata)")
        wif = Iam("Workload Identity\nFederation")

        with Cluster("GKE Autopilot Cluster: dep-dlm-staging-gke"):
            gke = GKE("GKE Autopilot\n(managed control plane)")

            with Cluster("k8s namespace: dep-dlm-staging", graph_attr=cluster_attr):
                ingress = Ingress("Ingress\n(DNS/TLS)")
                eso = Deployment("External Secrets\nOperator")
                rucio_server = Deployment("Rucio Server")
                rucio_daemons = Deployment("Rucio Daemons")
                fts = Deployment("FTS3")

    gitops >> Edge(label="sync", style="dashed") >> rucio_server
    ingress >> rucio_server

    wif >> Edge(label="federated\ncredential", style="dotted") >> eso
    eso >> Edge() >> sm
    rucio_server >> Edge() >> db
    rucio_server >> Edge() >> idp_ext
    rucio_daemons >> Edge(label="submit") >> fts

    fts >> Edge() >> source_rses
    fts >> Edge() >> dest_rses
    source_rses >> Edge() >> dest_rses
    gke >> Edge(style="invis") >> sm
