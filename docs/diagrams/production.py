"""
DEP DLM GitOps Deployment View — Production
Same externalization shape as staging (secrets/IdP/DB/storage all external
Regenerate: python3 production.py  (writes generated/production.png)
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.k8s.compute import Deployment
from diagrams.k8s.network import Ingress
from diagrams.onprem.database import PostgreSQL
from diagrams.onprem.security import Vault
from diagrams.onprem.gitops import Argocd
from diagrams.onprem.identity import Dex  # closest available generic OIDC IdP icon
from diagrams.generic.storage import Storage

graph_attr = {"fontsize": "22", "bgcolor": "white", "pad": "0.6", "splines": "ortho"}
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
    source_rses = Storage("Source RSEs\n(data holdings,\ndata spaces)")
    dest_rses = Storage("Destination RSEs\n(compute centres)")

    with Cluster("k8s: dep-dlm-production"):
        ingress = Ingress("Ingress\n(DNS/TLS)")
        eso = Deployment("External Secrets\nOperator")
        rucio_server = Deployment("Rucio Server\n(scaled)")
        rucio_daemons = Deployment("Rucio Daemons\n(scaled)")
        fts = Deployment("FTS3")

        gitops >> Edge(label="sync", style="dashed") >> rucio_server
        ingress >> rucio_server

        eso >> Edge(label="reads secrets") >> ext_vault
        rucio_server >> Edge(label="external DB") >> ext_db
        rucio_server >> Edge(label="OIDC") >> ext_idp
        rucio_daemons >> Edge(label="submit") >> fts

    fts >> Edge(label="TPC control\n(tokens)") >> source_rses
    fts >> Edge(label="TPC control\n(tokens)") >> dest_rses
    source_rses >> Edge(label="direct copy (bytes)", style="bold") >> dest_rses
