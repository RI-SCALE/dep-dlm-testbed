"""
DEP DLM GitOps Deployment View — Sandbox
Everything internal: bundled IdP, bundled storage, in-cluster Vault + DB.
Regenerate: python3 sandbox.py  (writes generated/sandbox.png)
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.k8s.compute import Deployment, Pod
from diagrams.onprem.database import PostgreSQL
from diagrams.onprem.security import Vault
from diagrams.onprem.gitops import Argocd

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
        rucio_server = Deployment("Rucio Server")
        rucio_daemons = Deployment("Rucio Daemons")
        fts = Deployment("FTS3")
        storage = Deployment("XRootD + Storm-WebDAV\n(bundled RSEs)")
        client = Pod("Rucio Client\n(test harness)")

        gitops >> Edge(label="sync", style="dashed") >> rucio_server

        eso >> Edge(label="reads secrets") >> vault
        rucio_server >> db
        rucio_server >> Edge(label="OIDC") >> idp
        client >> rucio_server
        rucio_daemons >> Edge(label="submit") >> fts
        fts >> Edge(label="TPC (davs)") >> storage
