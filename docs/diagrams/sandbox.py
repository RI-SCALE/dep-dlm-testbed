"""
DEP DLM GitOps Deployment View — Sandbox

Everything in-cluster: bundled IdP (Keycloak), storage (XRootD, StoRM WebDAV),
Vault and PostgreSQL, OPA with ODRL policies, and with OBSERVABILITY=1
Prometheus, Loki (fed by Alloy) and Grafana.

Edges carry no labels (Graphviz misplaces labels on orthogonal edges):
  solid = request/control, dashed = config (GitOps, secrets),
  dotted = telemetry.

Regenerate: python3 sandbox.py  (writes generated/sandbox.png)
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.k8s.compute import Deployment, Pod
from diagrams.onprem.database import PostgreSQL
from diagrams.onprem.security import Vault
from diagrams.onprem.gitops import Argocd
from diagrams.onprem.monitoring import Prometheus, Grafana
from diagrams.onprem.logging import Loki

graph_attr = {"fontsize": "22", "bgcolor": "white", "pad": "0.6", "splines": "polyline"}
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
        db = PostgreSQL("PostgreSQL")
        idp = Deployment("Keycloak\n(bundled IdP)")
        opa = Deployment("OPA\n(ODRL policies\nby Job)")
        rucio_server = Deployment("Rucio Server")
        rucio_daemons = Deployment("Rucio Daemons")
        fts = Deployment("FTS3")
        storage = Deployment("XRootD +\nStoRM WebDAV")
        client = Pod("Rucio Client\n(test harness)")

        with Cluster("Observability (OBSERVABILITY=1)"):
            exporters = Deployment("SQL exporters")
            alloy = Deployment("Alloy")
            prom = Prometheus("Prometheus\n+ Alertmanager")
            loki = Loki("Loki")
            grafana = Grafana("Grafana")

        gitops >> Edge(style="dashed") >> rucio_server

        eso >> Edge(style="dashed") >> vault
        rucio_server >> db
        rucio_server >> idp
        rucio_server >> opa
        client >> rucio_server
        rucio_daemons >> fts
        fts >> storage

        prom >> Edge(style="dotted") >> [rucio_server, rucio_daemons, fts, exporters]
        alloy >> Edge(style="dotted") >> loki
        grafana >> Edge(style="dotted") >> [prom, loki]
