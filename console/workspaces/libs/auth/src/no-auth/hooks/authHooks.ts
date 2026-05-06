/**
 * Copyright (c) 2025, WSO2 LLC. (https://www.wso2.com).
 *
 * WSO2 LLC. licenses this file to you under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */


import { UserInfo } from '../../types';
import { globalConfig } from '@agent-management-platform/types';

let cachedLocalToken: string | null = null;

function getLocalTokenEndpoint(): string {
  const configuredBaseUrl = globalConfig.authConfig?.baseUrl || 'http://localhost:8082';

  try {
    const url = new URL(configuredBaseUrl);
    return `${url.origin}/oauth2/token`;
  } catch {
    return 'http://localhost:8082/oauth2/token';
  }
}

async function getLocalDevToken(): Promise<string> {
  if (cachedLocalToken) {
    return cachedLocalToken;
  }

  const response = await fetch(getLocalTokenEndpoint(), {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({
      grant_type: 'client_credentials',
      client_id: 'amp-api-client',
      client_secret: 'amp-api-client-secret',
      scope: 'openid system',
    }).toString(),
  });

  if (!response.ok) {
    throw new Error(`Failed to obtain local dev token: ${response.status}`);
  }

  const data = await response.json() as { access_token?: string };

  if (!data.access_token) {
    throw new Error('Thunder token response did not include access_token');
  }

  cachedLocalToken = data.access_token;
  return data.access_token;
}

const demoUserInfo : UserInfo = {
  username: 'john.doe',
  displayName: 'John Doe',
  orgHandle: 'default',
  orgId: 'default',
  orgName: 'Default',
  sessionState: '',
  sub: 'default',
  allowedScopes: "openid email profile",
};

export const refreshToken = async () => {
  cachedLocalToken = null;
  return Promise.resolve();
}
export const useAuthHooks = () => {
  return {
    isAuthenticated: true,
    userInfo: demoUserInfo,
    isLoadingUserInfo: false,
    isLoadingIsAuthenticated: false,
    login: () => Promise.resolve(),
    logout: () => Promise.resolve(),
    trySignInSilently: () => Promise.resolve(),
    getToken: () => getLocalDevToken(),
  };
};
