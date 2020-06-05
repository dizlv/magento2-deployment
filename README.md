# Notes
Since this is kind of test-task, there are a lot of things to improve here. But the basic+ setup is implemented.

- Depoy AWS infrastructure via `terraform apply`
- Provision servers via ansible.

`ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook site.yaml -i inventories/scandiweb`

Vault Password: `scandiweb`

PS. Self signed certificate for domain `scandiweb.lv` has been created for this task.

# Some further improvements

1. Create more servers (separate database & probably nginx, put them in own autoscaling groups).
2. Log metrics & based on them create autoscaling policies
3. Centralize logs.
4. Consider using RDS.
5. Consider using Packer to bake images & pull out configuration deployment. In that way you can speed up deployment process a lot (this also works for autoscaling).