# CI/CD Integration with Genymotion

> **Note**: CI/CD integration is only supported with **Genymotion SaaS** (`gmsaas`), not Genymotion Desktop (`gmtool`).

## Official tutorials

| Platform | Resource |
|----------|----------|
| **GitHub Actions** | https://github.com/marketplace/actions/genymotion-saas-action |
| **Jenkins** | https://www.genymotion.com/blog/tutorial/jenkins-genymotion-saas/ |
| **Bitrise** | https://www.genymotion.com/blog/tutorial/bitrise-genymotion-saas/ |
| **CircleCI** | https://www.genymotion.com/blog/tutorial/auto-tests-circelci-genymotion-saas/ |
| **React Native + Detox** | https://www.genymotion.com/blog/tutorial/react_native_detox_genymotion_saas/ |

## Security

> Store `GENYMOTION_API_TOKEN` as a CI secret — never hardcode it in your pipeline file.

## Finding your recipe UUID

```bash
gmsaas recipes list
```

Pick the recipe matching the Android version and hardware profile you need.
