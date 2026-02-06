# Enterprise Data Lakehouse Platform

A fully integrated, production-ready open-source data lakehouse on WSL2/Ubuntu with Ansible automation. Every component is idempotent, self-contained, and enterprise-ready.

## Architecture Overview

```
                    ┌──────────────────────────────────────┐
                    │       Homer Dashboard (:8090)         │
                    │      Service Discovery & Portal       │
                    └──────────────┬───────────────────────┘
                                   │
        ┌──────────────────────────┼──────────────────────────┐
        │                          │                          │
  ┌─────┴─────┐            ┌──────┴──────┐           ┌───────┴──────┐
  │  Storage   │            │  Processing │           │  Data Science│
  │  Layer     │            │  Layer      │           │  Layer       │
  ├───────────┤            ├─────────────┤           ├──────────────┤
  │ SeaweedFS │            │ Spark Master│           │ JupyterLab   │
  │ S3 API    │◄──────────►│ Spark Worker│           │ (PySpark)    │
  │ Filer     │            │ Thrift Srv  │           │              │
  └───────────┘            │ History Srv │           └──────────────┘
                           └──────┬──────┘
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        │                         │                         │
  ┌─────┴──────┐          ┌──────┴──────┐          ┌───────┴──────┐
  │  Catalog   │          │ Query Eng.  │          │  Orchestr.   │
  ├────────────┤          ├─────────────┤          ├──────────────┤
  │ Nessie     │          │ Databend    │          │ Airflow      │
  │ (Iceberg)  │          │ Trino       │          │ Superset     │
  └────────────┘          └─────────────┘          └──────────────┘
        │                                                  │
        └──────────────┐                  ┌────────────────┘
                  ┌────┴────────────────┴─────┐
                  │    Shared Services         │
                  │  PostgreSQL  │  Redis      │
                  └───────────────────────────┘
```

## Prerequisites

- **WSL2 Ubuntu** with 4-8GB RAM allocated
- **containerd + nerdctl** (no Docker)
- **Ansible** installed
- **SeaweedFS** deployed (provides `seaweedfs_default` network)
- **Databend** deployed (optional, query engine)

## Quick Start

```bash
# Deploy core platform (Phase 0+1, ~2.5GB RAM)
cd ansible
ansible-playbook 260206_deploy_all_lakehouse_rb_v1_0.yaml

# Deploy full stack including Trino, Airflow, Superset (~4GB RAM)
ansible-playbook 260206_deploy_all_lakehouse_rb_v1_0.yaml -e deploy_phase_2=true

# Health check
bash health_check.sh

# Teardown (keep data)
ansible-playbook 260206_teardown_lakehouse_rb_v1_0.yaml

# Teardown (delete data)
ansible-playbook 260206_teardown_lakehouse_rb_v1_0.yaml -e delete_data=true
```

## Deployment Phases

### Phase 0: Portal & Shared Services (~250MB)

| Component | Playbook | Port | Purpose |
|-----------|----------|------|---------|
| Homer Dashboard | `260206_homer-dashboard_rb_v1_0.yaml` | 8090 | Service discovery portal |
| PostgreSQL | `260206_shared-services_rb_v1_0.yaml` | 5432 | Shared relational database |
| Redis | `260206_shared-services_rb_v1_0.yaml` | 6379 | Shared cache |

### Phase 1: Core Data Platform (~1.25GB)

| Component | Playbook | Ports | Purpose |
|-----------|----------|-------|---------|
| Spark Master | `260206_spark-thrift_rb_v1_0.yaml` | 8081, 7077 | Distributed processing |
| Spark Worker | (same) | 8082 | Worker node |
| Spark Thrift | (same) | 10000 | SQL over JDBC |
| Spark History | (same) | 18080 | Job history |
| Nessie Catalog | `260206_nessie-catalog_rb_v1_0.yaml` | 19120 | Git-like data versioning |
| JupyterLab | `260206_jupyter-pyspark_rb_v1_0.yaml` | 8889 | Interactive notebooks |

### Phase 2: Extended Platform (~1.35GB)

| Component | Playbook | Port | Purpose |
|-----------|----------|------|---------|
| Trino | `260206_trino-sql_rb_v1_0.yaml` | 8085 | Federated SQL engine |
| Airflow | `260206_airflow-orchestration_rb_v1_0.yaml` | 8086 | Workflow orchestration |
| Superset | `260206_superset-bi_rb_v1_0.yaml` | 8088 | BI dashboards |

## Individual Deployment

Each component can be deployed independently:

```bash
# Phase 0
ansible-playbook 260206_homer-dashboard_rb_v1_0.yaml
ansible-playbook 260206_shared-services_rb_v1_0.yaml

# Phase 1
ansible-playbook 260206_spark-thrift_rb_v1_0.yaml
ansible-playbook 260206_nessie-catalog_rb_v1_0.yaml
ansible-playbook 260206_jupyter-pyspark_rb_v1_0.yaml

# Phase 2
ansible-playbook 260206_trino-sql_rb_v1_0.yaml
ansible-playbook 260206_airflow-orchestration_rb_v1_0.yaml
ansible-playbook 260206_superset-bi_rb_v1_0.yaml
```

## Port Allocation

```
Storage:                    Query Engines:
  8333  SeaweedFS S3 API      3307  Databend MySQL
  8888  SeaweedFS Filer       8000  Databend HTTP
  9333  SeaweedFS Master      8085  Trino
                              28080 Databend UI

Processing:                 Data Science:
  7077  Spark Master RPC      8889  JupyterLab
  8081  Spark Master UI
  8082  Spark Worker UI     Catalog & Orchestration:
  10000 Spark Thrift          19120 Nessie REST API
  18080 Spark History         8086  Airflow Webserver

BI & Portal:               Shared Services:
  8088  Superset              5432  PostgreSQL
  8090  Homer Dashboard       6379  Redis
```

## Default Credentials

| Service | Username | Password |
|---------|----------|----------|
| JupyterLab | - | token: `lakehouse` |
| Airflow | `admin` | `admin` |
| Superset | `admin` | `admin` |
| PostgreSQL | `lakehouse` | `lakehouse` |
| SeaweedFS S3 | `dev` | `dev` |

## S3 Configuration

All services connect to SeaweedFS S3 via the shared network:

- **From host**: `http://localhost:8333`
- **From containers**: `http://s3:8333`
- **Access key**: `dev`
- **Secret key**: `dev`
- **Path style**: enabled

## Component Dependencies

```
Homer Dashboard       → seaweedfs_default network
Shared Services       → seaweedfs_default network
Spark                 → seaweedfs_default network, SeaweedFS S3
Nessie                → Shared Services (PostgreSQL)
JupyterLab            → Spark Master, SeaweedFS S3
Trino                 → Nessie, SeaweedFS S3
Airflow               → Shared Services (PostgreSQL)
Superset              → Shared Services (PostgreSQL + Redis)
```

## File Structure

```
/opt/lakehouse/
├── homer/                  # Homer Dashboard
│   ├── assets/config.yml   # Dashboard configuration
│   └── compose.yaml
├── shared-services/        # PostgreSQL + Redis
│   ├── init-databases.sh   # Multi-database init script
│   ├── postgres-data/      # PostgreSQL data volume
│   ├── redis-data/         # Redis AOF data
│   └── compose.yaml
├── spark/                  # Apache Spark
│   ├── jars/               # Iceberg + Delta Lake JARs
│   ├── spark-events/       # History server events
│   ├── conf/               # spark-defaults.conf
│   └── compose.yaml
├── nessie/                 # Project Nessie
│   └── compose.yaml
├── jupyter/                # JupyterLab
│   ├── notebooks/          # User notebooks
│   ├── conf/               # Spark config for Jupyter
│   └── compose.yaml
├── trino/                  # Trino SQL
│   ├── catalog/            # Connector configs
│   ├── etc/                # Trino server configs
│   └── compose.yaml
├── airflow/                # Apache Airflow
│   ├── dags/               # DAG definitions
│   ├── logs/               # Execution logs
│   ├── plugins/            # Custom plugins
│   └── compose.yaml
└── superset/               # Apache Superset
    ├── config/             # superset_config.py
    └── compose.yaml
```

## Idempotency

All playbooks are designed to be run multiple times safely:

```bash
# First run: creates everything
ansible-playbook 260206_homer-dashboard_rb_v1_0.yaml

# Second run: recreates containers, preserves data
ansible-playbook 260206_homer-dashboard_rb_v1_0.yaml
```

## Monitoring

```bash
# Health check all services
bash ansible/health_check.sh

# Check memory usage
free -h

# Container resource usage
nerdctl stats

# Check specific container logs
nerdctl logs spark-master
nerdctl logs nessie
```

## Networking

All containers share the `seaweedfs_default` bridge network created by the SeaweedFS deployment. This allows inter-container DNS resolution by container name.

```bash
# Verify network
nerdctl network inspect seaweedfs_default

# Test connectivity from inside a container
nerdctl exec spark-master ping -c 1 s3
nerdctl exec jupyter ping -c 1 nessie
```
