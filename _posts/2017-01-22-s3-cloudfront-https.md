---
title: Moved to AWS Blog Hosting (S3 + CloudFront + Route53)
subtitle: Because Github Pages has no HTTPS for custom domains :(
---

Well that was quick! Apparently Github Pages does not support HTTPS with custom domains. Luckily, it was easy enough to publish the Jekyll site to S3 and serve it via CloudFront. Here's a [great blog post with full instructions](https://olivermak.es/2016/01/aws-tls-certificate-with-jekyll/). 

During the process, I did learn a little trick while [generating the SSL certificate](https://aws.amazon.com/certificate-manager/). AWS emails the domain administrator to verify the SSL cert request. This was a problem because I had no email set up for my theza.ch domain. I didn't want to pay for any email hosting, so instead I set up [SES to save received email to an S3 bucket](http://docs.aws.amazon.com/ses/latest/DeveloperGuide/receiving-email-action-s3.html) and added MX records to my domain in Route53 that point to SES. When AWS sent the SSL verification email to administrator@theza.ch I just downloaded the email from the S3 bucket and got the verification link from it.

So now I have cheap, reliable, high-performance hosting for my blog, powerful DNS, and also got email support and an SSL certificate for free!
