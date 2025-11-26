# RabbitMQ Operator

Note on pod 0: 4.1 also changed how k8s peer discover works and currently if you lose server-0 (the pod with index 0), it won't rejoin the cluster automatically. Other nodes will rejoin.
