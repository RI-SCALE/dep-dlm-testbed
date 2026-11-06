"""
DEP DLM GitOps Deployment View — Staging (GCP)

Only the data-orchestration engine (Rucio + FTS) and its policy decision
point (OPA, policies from the external ODRL repository) run in-cluster, on a
zonal GKE Standard cluster with a single fixed-size node (ADR-009). Secrets
(Secret Manager), databases (Cloud SQL for PostgreSQL and MySQL), IdP
(external AAI federation hub) and storage RSEs are external. Production has
the same shape with an autoscaling node pool.

Public ingress is the GKE Gateway API (gatewayClassName
gke-l7-global-external-managed), which provisions a global external
Application Load Balancer on the reserved static IP (gateway_static_ip).
rucio.* and fts.* route through the same Gateway via Host-header matching.

validation-storage is a testbed-owned GCE VM (Container-Optimized OS, not
GKE) running XRootD (xrd3/xrd4) and Teapot WebDAV (teapot1/teapot2) via
docker compose, registered as real RSEs so FTS exercises an external network
path. It is resolved through a private Cloud DNS zone, not by IP: FTS's
gfal2/davix transfer engine does not honour per-pod /etc/hosts entries. It
trusts the same CA chain from the Secret Manager "certs" secret.

Telemetry lives outside the cluster (design doc 005): Managed Service for
Prometheus collects metrics from rucio-server, the daemons and the
sql_exporters into Cloud Monitoring; GKE ships container stdout to Cloud
Logging. Dashboards and alert policies are Terraform-managed Cloud
Monitoring resources and logs are read in the Logs Explorer, so visibility
survives a cluster outage. In-cluster are only the exporters, the
PodMonitoring resources and GKE's managed agents (GMP collectors, logging
agent), none of which store data.

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
    "splines": "ortho",
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

    gitops >> Edge(label="sync", style="dashed") >> rucio_server

    glb >> Edge(label="rucio.* / fts.*\n(Host header)") >> gateway
    gateway >> rucio_server
    gateway >> fts

    wif >> Edge(label="federated\ncredential", style="dotted") >> eso
    eso >> sm
    rucio_server >> rucio_db
    rucio_server >> idp_ext
    rucio_server >> Edge(label="authz") >> opa
    opa >> Edge(label="policy bundle", style="dashed") >> policies
    rucio_daemons >> Edge(label="submit") >> fts
    fts >> fts_db

    # Telemetry (design doc 005): collected in-cluster, stored and viewed outside it
    rucio_server >> Edge(label="metrics\n(PodMonitoring)", style="dashed") >> monitoring
    rucio_daemons >> Edge(style="dashed") >> monitoring
    exporters >> Edge(style="dashed") >> monitoring
    exporters >> Edge(label="SQL", style="dotted") >> rucio_db
    exporters >> Edge(style="dotted") >> fts_db
    gke >> Edge(label="container\nstdout", style="dashed") >> logging

    fts >> source_rses
    fts >> dest_rses
    source_rses >> Edge(label="direct copy", style="bold") >> dest_rses

    dns >> Edge(label="A record", style="dashed") >> valstorage_vm
    fts >> valstorage_vm
    sm >> Edge(label="certs +\nCA chain") >> valstorage_vm
