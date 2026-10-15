"""
DEP DLM GitOps Deployment View — Staging
Only the data-orchestration engine (Rucio + FTS) and its policy decision
point (OPA) stay in-cluster; secrets, IdP, DB, storage RSEs and the ODRL
policy source are external. Observability is split the same way: thin
collectors in-cluster (Alloy, SQL exporters), storage/UI in an external
backend (central or provider-managed). Structurally identical to
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
from diagrams.onprem.monitoring import Grafana
from diagrams.generic.storage import Storage
from diagrams.programming.flowchart import Document

graph_attr = {"fontsize": "22", "bgcolor": "white", "pad": "0.6", "splines": "ortho"}
node_attr = {"fontsize": "11"}

with Diagram(
    "DEP DLM — Staging (secrets, IdP, DB, storage, policies, telemetry backend external)",
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
    ext_policies = Document("ODRL policy\nrepository (WP4)")
    ext_obs = Grafana(
        "Observability backend\n(Prometheus/Loki/Grafana,\ncentral or managed)"
    )
    source_rses = Storage("Source RSEs\n(data holdings,\ndata spaces)")
    dest_rses = Storage("Destination RSEs\n(compute centres)")

    with Cluster("k8s: dep-dlm-staging"):
        ingress = Ingress("Ingress\n(DNS/TLS)")
        eso = Deployment("External Secrets\nOperator")
        opa = Deployment("OPA\n(authz)")
        rucio_server = Deployment("Rucio Server")
        rucio_daemons = Deployment("Rucio Daemons")
        fts = Deployment("FTS3")
        collectors = Deployment("Telemetry collectors\n(Alloy, SQL exporters)")

        gitops >> Edge(label="sync", style="dashed") >> rucio_server
        ingress >> rucio_server

        eso >> Edge(label="reads secrets") >> ext_vault
        rucio_server >> Edge(label="external DB") >> ext_db
        rucio_server >> Edge(label="OIDC") >> ext_idp
        rucio_server >> Edge(label="authz") >> opa
        rucio_daemons >> Edge(label="submit") >> fts
        (
            collectors
            >> Edge(label="scrape / tail", style="dotted")
            >> [rucio_server, rucio_daemons, fts]
        )

    opa >> Edge(label="policy bundle", style="dashed") >> ext_policies
    collectors >> Edge(label="remote_write\n+ logs", style="dotted") >> ext_obs
    fts >> Edge(label="TPC control\n(tokens)") >> source_rses
    fts >> Edge(label="TPC control\n(tokens)") >> dest_rses
    source_rses >> Edge(label="direct copy (bytes)", style="bold") >> dest_rses
