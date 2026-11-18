"""
DEP DLM GitOps Deployment View — Production

Rucio, FTS and OPA run in-cluster; secrets, IdP, DB, storage RSEs, the ODRL
policy source and the telemetry backend are external, with thin collectors
(Alloy, SQL exporters) in-cluster. Staging shape plus HA and public ingress.

Edges carry no labels (Graphviz misplaces edge labels):
  solid = request/control, dashed = config (GitOps, secrets, policy),
  dotted = telemetry, bold = data (bytes).

Regenerate: python3 production.py  (writes generated/production.png)
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.k8s.compute import Deployment
from diagrams.k8s.network import Ingress
from diagrams.onprem.database import PostgreSQL
from diagrams.onprem.security import Vault
from diagrams.onprem.gitops import Argocd
from diagrams.onprem.identity import Dex  # closest available generic OIDC IdP icon
from diagrams.onprem.monitoring import Grafana
from diagrams.generic.storage import Storage
from diagrams.programming.flowchart import Document

graph_attr = {"fontsize": "22", "bgcolor": "white", "pad": "0.6", "splines": "polyline"}
node_attr = {"fontsize": "11"}

with Diagram(
    "DEP DLM — Production (staging shape + HA/ingress)",
    filename="generated/production",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr,
):
    gitops = Argocd("GitOps engine\n(Argo CD or Flux)")

    ext_vault = Vault("Partner Vault\n(K8s auth)")
    ext_idp = Dex("External IdP\n(EGI Check-In /\nLS AAI / partner)")
    ext_db = PostgreSQL("Managed\nPostgreSQL")
    ext_policies = Document("ODRL policy\nrepository (WP4)")
    ext_obs = Grafana("Observability backend\n(central or managed)")
    source_rses = Storage("Source RSEs")
    dest_rses = Storage("Destination RSEs")

    with Cluster("k8s: dep-dlm-production"):
        ingress = Ingress("Ingress\n(DNS/TLS)")
        eso = Deployment("External Secrets\nOperator")
        opa = Deployment("OPA\n(scaled)")
        rucio_server = Deployment("Rucio Server\n(scaled)")
        rucio_daemons = Deployment("Rucio Daemons\n(scaled)")
        fts = Deployment("FTS3")
        collectors = Deployment("Telemetry collectors\n(Alloy, SQL exporters)")

        gitops >> Edge(style="dashed") >> rucio_server
        ingress >> rucio_server

        eso >> Edge(style="dashed") >> ext_vault
        rucio_server >> ext_db
        rucio_server >> ext_idp
        rucio_server >> opa
        rucio_daemons >> fts
        collectors >> Edge(style="dotted") >> [rucio_server, rucio_daemons, fts]

    opa >> Edge(style="dashed") >> ext_policies
    collectors >> Edge(style="dotted") >> ext_obs
    fts >> source_rses
    fts >> dest_rses
    source_rses >> Edge(style="bold") >> dest_rses
