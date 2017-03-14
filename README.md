# DealMon
Deal Monitoring program written in Ruby

## Requirements
 - Ruby - 2.3 tested
 - Bundler gem - 1.13.6 tested

## Features
 - Support for the following sites:
   - Frys.com
 - Email alerts when criteria is met
 - Periodic checks with option for randomized jitter

## Usage
1. Create a copy of config.json.example and save as config.json . This file is used to configure which deals should be monitored, what criteria they should meet, and email alert settings.
2. Edit config.json with links to products to monitor, the alert criteria, the alert email list, and smtp email account settings
3. Start program with:
```sh
ruby checker.rb
```

Example alert email:
```
Date: Sat, 04 Mar 2017 00:00:00 -0800 (PST)
From: DealMon <myotheremail@email.com>
To: <me@email.com>
Subject: DealMon: Patriot Viper Xtreme Edition DDR4 16GB (2x8GB) 2400MHz Low Latency Dual Channel Kit

Your deal was found!
Product: Patriot Viper Xtreme Edition DDR4 16GB (2x8GB) 2400MHz Low Latency Dual Channel Kit
Link: http://www.frys.com/product/8911983
Price: $68.99
Stores: ["Sunnyvale"]

Your deal criteria:
{:stock=>"available", :zip_code=>94085, :price_below_usd=>80.0, :stores=>["Sunnyvale"]}
```

## Notes
Use of this program may violate the Terms of Service for the sites it checks. Use at your own risk.

Frys is only supported through some fragile HTML parsing that can break with minor changes to their site.

Frys has unreliable stock information on their site so this tool may give false positives if the site says it's in stock somewhere but doesn't let you check out with it.
