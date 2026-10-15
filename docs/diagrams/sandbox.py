"""
DEP DLM GitOps Deployment View — Sandbox
Everything internal: bundled IdP, bundled storage, in-cluster Vault + DB,
OPA as policy decision point, and (OBSERVABILITY=1) the full observability
stack: Alloy ships logs to Loki, Prometheus scrapes Rucio/FTS and the
SQL exporters, Grafana reads both.
Regenerate: python3 sandbox.py  (writes generated/sandbox.png)
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.k8s.compute import Deployment, Pod
from diagrams.onprem.database import PostgreSQL
from diagrams.onprem.security import Vault
from diagrams.onprem.gitops import Argocd
from diagrams.onprem.monitoring import Prometheus, Grafana
from diagrams.onprem.logging import Loki

graph_attr = {"fontsize": "22", "bgcolor": "white", "pad": "0.6", "splines": "ortho"}
node_attr = {"fontsize": "11"}

with Diagram(
    "DEP DLM — Sandbox (fully internal)",
    filename="generated/sandbox",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr,
):
    gitops = Argocd("GitOps engine\n(Argo CD or Flux)")

    with Cluster("k8s: dep-dlm-sandbox"):
        eso = Deployment("External Secrets\nOperator")
        vault = Vault("Vault (dev)\nseeded by Job")
        db = PostgreSQL("PostgreSQL\n(in-cluster)")
        idp = Deployment("Keycloak\n(bundled IdP,\nself-signed CA)")
        opa = Deployment("OPA\n(authz, ODRL policies\ningested by Job)")
        rucio_server = Deployment("Rucio Server")
        rucio_daemons = Deployment("Rucio Daemons")
        fts = Deployment("FTS3")
        storage = Deployment("XRootD + Storm-WebDAV\n(bundled RSEs)")
        client = Pod("Rucio Client\n(test harness)")

        with Cluster("Observability (OBSERVABILITY=1)"):
            exporters = Deployment("SQL exporters\n(Rucio DB, FTS DB)")
            alloy = Deployment("Alloy\n(pod logs)")
            prom = Prometheus("Prometheus\n+ Alertmanager")
            loki = Loki("Loki")
            grafana = Grafana("Grafana")

        gitops >> Edge(label="sync", style="dashed") >> rucio_server

        eso >> Edge(label="reads secrets") >> vault
        rucio_server >> db
        rucio_server >> Edge(label="OIDC") >> idp
        rucio_server >> Edge(label="authz") >> opa
        client >> rucio_server
        rucio_daemons >> Edge(label="submit") >> fts
        fts >> Edge(label="TPC (davs)") >> storage

        (
            prom
            >> Edge(label="scrape", style="dotted")
            >> [rucio_server, rucio_daemons, fts, exporters]
        )
        alloy >> Edge(label="push logs", style="dotted") >> loki
        grafana >> Edge(style="dotted") >> [prom, loki]
