// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

package dbmigrations

import (
	"gorm.io/gorm"
)

// migration026 narrows agent OAuth config to authentication-only. The gateway
// jwt-auth policy never implemented audiences/required-scopes (authorization),
// so those columns are dropped. forwardToken is added to control whether the
// validated token header is forwarded to the upstream service.
//
// TEMPORARY: this is split out so it can be applied and tested on top of an
// already-migrated dev DB. Before pushing, fold these changes into
// migration025 and delete this file (revert latestVersion to 25).
var migration026 = migration{
	ID: 26,
	Migrate: func(db *gorm.DB) error {
		stmt := `
		ALTER TABLE agent_configs
			DROP COLUMN IF EXISTS oauth_audiences,
			DROP COLUMN IF EXISTS oauth_required_scopes,
			ADD COLUMN IF NOT EXISTS oauth_forward_token BOOLEAN NOT NULL DEFAULT true;
		`
		return db.Exec(stmt).Error
	},
}
