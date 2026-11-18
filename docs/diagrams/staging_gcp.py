"""
DEP DLM GitOps Deployment View — Staging (GCP)

Rucio, FTS and OPA run on a zonal GKE Standard cluster with one fixed node
(ADR-009); secrets, databases, IdP, storage RSEs and telemetry storage are
external. The GKE Gateway (global external ALB on gateway_static_ip) routes
rucio.* and fts.* by Host header. validation-storage is a testbed-owned GCE VM
(XRootD xrd3/xrd4, Teapot teapot1/teapot2) resolved via a private DNS zone.

Edges carry no labels (Graphviz misplaces labels on orthogonal edges):
  solid = request/control, dashed = config (GitOps, secrets, certs, policy, DNS),
  dotted = telemetry, bold = data (bytes).

Regenerate: python3 staging-gcp.py  (writes generated/staging-gcp.png)
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.gcp.compute import GKE, ComputeEngine
from diagrams.gcp.database import SQL
from diagrams.gcp.network import LoadBalancing, DNS
from diagrams.gcp.security import SecretManager, Iam
from diagrams.gcp.operations import Monitoring, Logging
from diagrams.k8s.compute import Deployment
from diagrams.k8s.network import Ingress
from diagrams.onprem.gitops import Argocd
from diagrams.generic.network import Firewall
from diagrams.generic.storage import Storage
from diagrams.programming.flowchart import Document

graph_attr = {
    "fontsize": "22",
    "bgcolor": "white",
    "pad": "0.6",
    "splines": "polyline",
    "nodesep": "0.7",
    "ranksep": "0.9",
}
node_attr = {"fontsize": "11"}
cluster_attr = {"margin": "30"}

with Diagram(
    "DEP DLM — Staging (GCP, GKE Standard, single node)",
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
    policies = Document("ODRL policy\nrepository (WP4)")

    with Cluster("GCP Project: dep-dlm-staging"):
        sm = SecretManager("Secret Manager\n(secrets + certs,\nshared CA chain)")
        rucio_db = SQL("Cloud SQL\nfor PostgreSQL\n(Rucio)")
        fts_db = SQL("Cloud SQL\nfor MySQL\n(FTS)")
        wif = Iam("Workload Identity")
        glb = LoadBalancing("Global External ALB\n(GKE Gateway,\ngateway_static_ip)")
        dns = DNS("Cloud DNS\n(private zone)")
        monitoring = Monitoring(
            "Cloud Monitoring\n(Managed Prometheus,\ndashboards, alert policies)"
        )
        logging = Logging("Cloud Logging\n(Logs Explorer)")

        with Cluster(
            "GKE Standard (zonal): dep-dlm-staging-gke\nnode pool: 1 fixed node, no autoscaling"
        ):
            gke = GKE("GKE\ncontrol plane")

            with Cluster("k8s namespace: dep-dlm-staging", graph_attr=cluster_attr):
                gateway = Ingress("Gateway API\n(Gateway + HTTPRoute)")
                eso = Deployment("External Secrets\nOperator")
                rucio_server = Deployment("Rucio Server")
                rucio_daemons = Deployment("Rucio Daemons")
                fts = Deployment("FTS3")
                opa = Deployment("OPA\n(authz)")
                exporters = Deployment("sql_exporter\n(Rucio, FTS)")

        with Cluster(
            "GCE VM: dep-dlm-staging-validation-storage\n(public IP, not GKE)",
            graph_attr=cluster_attr,
        ):
            valstorage_fw = Firewall("Firewall rule\n(:1094-1095, 8081-8082)")
            valstorage_vm = ComputeEngine(
                "docker compose:\nxrd3/xrd4 (XRootD)\nteapot1/teapot2 (WebDAV)"
            )
            valstorage_fw >> valstorage_vm

    gitops >> Edge(style="dashed") >> rucio_server

    glb >> gateway
    gateway >> rucio_server
    gateway >> fts

    wif >> Edge(style="dashed") >> eso
    eso >> Edge(style="dashed") >> sm
    rucio_server >> rucio_db
    rucio_server >> idp_ext
    rucio_server >> opa
    opa >> Edge(style="dashed") >> policies
    rucio_daemons >> fts
    fts >> fts_db

    # Telemetry (design doc 005): collected in-cluster, stored and viewed outside it
    rucio_server >> Edge(style="dotted") >> monitoring
    rucio_daemons >> Edge(style="dotted") >> monitoring
    exporters >> Edge(style="dotted") >> monitoring
    exporters >> Edge(style="dotted") >> rucio_db
    exporters >> Edge(style="dotted") >> fts_db
    gke >> Edge(style="dotted") >> logging

    fts >> source_rses
    fts >> dest_rses
    source_rses >> Edge(style="bold") >> dest_rses

    dns >> Edge(style="dashed") >> valstorage_vm
    fts >> valstorage_vm
    sm >> Edge(style="dashed") >> valstorage_vm
