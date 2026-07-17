"""
DEP DLM GitOps Deployment View — Staging
Only the data-orchestration engine (Rucio + FTS) stays in-cluster; secrets,
IdP, DB and storage RSEs are all external. Structurally identical to
production by design.
Regenerate: python3 staging.py  (writes generated/staging.png)
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
    "DEP DLM — Staging (secrets, IdP, DB, storage external)",
    filename="generated/staging",
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

    with Cluster("k8s: dep-dlm-staging"):
        ingress = Ingress("Ingress\n(DNS/TLS)")
        eso = Deployment("External Secrets\nOperator")
        rucio_server = Deployment("Rucio Server")
        rucio_daemons = Deployment("Rucio Daemons")
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
