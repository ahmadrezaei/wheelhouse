import Foundation

public struct YAMLTemplate: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var symbol: String
    public var yaml: String

    public static let all: [YAMLTemplate] = [deployment, service, configMap, secret, job, cronJob, ingress, namespace, networkPolicy, persistentVolumeClaim]

    public static let deployment = YAMLTemplate(name: "Deployment", symbol: "square.stack.3d.up", yaml: """
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: my-app
      labels:
        app: my-app
    spec:
      replicas: 2
      selector:
        matchLabels:
          app: my-app
      template:
        metadata:
          labels:
            app: my-app
        spec:
          containers:
            - name: app
              image: nginx:1.27
              ports:
                - containerPort: 80
              resources:
                requests:
                  cpu: 50m
                  memory: 64Mi
                limits:
                  memory: 128Mi

    """)

    public static let service = YAMLTemplate(name: "Service", symbol: "point.3.connected.trianglepath.dotted", yaml: """
    apiVersion: v1
    kind: Service
    metadata:
      name: my-app
    spec:
      type: ClusterIP
      selector:
        app: my-app
      ports:
        - name: http
          port: 80
          targetPort: 80

    """)

    public static let configMap = YAMLTemplate(name: "ConfigMap", symbol: "doc.plaintext", yaml: """
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: my-config
    data:
      LOG_LEVEL: info
      app.properties: |
        feature.enabled=true
        timeout=30

    """)

    public static let secret = YAMLTemplate(name: "Secret", symbol: "key", yaml: """
    apiVersion: v1
    kind: Secret
    metadata:
      name: my-secret
    type: Opaque
    stringData:
      username: admin
      password: change-me

    """)

    public static let job = YAMLTemplate(name: "Job", symbol: "checkmark.square", yaml: """
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: my-job
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: job
              image: busybox:1.36
              command: ["sh", "-c", "echo hello && sleep 5"]

    """)

    public static let cronJob = YAMLTemplate(name: "CronJob", symbol: "calendar.badge.clock", yaml: """
    apiVersion: batch/v1
    kind: CronJob
    metadata:
      name: my-cronjob
    spec:
      schedule: "*/15 * * * *"
      concurrencyPolicy: Forbid
      jobTemplate:
        spec:
          template:
            spec:
              restartPolicy: OnFailure
              containers:
                - name: task
                  image: busybox:1.36
                  command: ["sh", "-c", "date"]

    """)

    public static let ingress = YAMLTemplate(name: "Ingress", symbol: "arrow.right.to.line", yaml: """
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    metadata:
      name: my-app
    spec:
      rules:
        - host: app.example.com
          http:
            paths:
              - path: /
                pathType: Prefix
                backend:
                  service:
                    name: my-app
                    port:
                      number: 80

    """)

    public static let namespace = YAMLTemplate(name: "Namespace", symbol: "folder", yaml: """
    apiVersion: v1
    kind: Namespace
    metadata:
      name: my-namespace

    """)

    public static let networkPolicy = YAMLTemplate(name: "NetworkPolicy", symbol: "shield.lefthalf.filled", yaml: """
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: default-deny-ingress
    spec:
      podSelector: {}
      policyTypes:
        - Ingress

    """)

    public static let persistentVolumeClaim = YAMLTemplate(name: "PVC", symbol: "cylinder", yaml: """
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: my-data
    spec:
      accessModes: [ReadWriteOnce]
      resources:
        requests:
          storage: 1Gi

    """)
}
