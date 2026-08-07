import { Navigate, Route, Routes } from 'react-router-dom'
import { useAuthUser } from './data/auth'
import { SignInPage } from './ui/SignInPage'
import { UIDProvider } from './ui/UserContext'
import { AppShell } from './ui/shell/AppShell'
import { NotFound } from './ui/shell/NotFound'
import { FeedPage } from './ui/feed/FeedPage'
import { FollowUpsPage } from './ui/followups/FollowUpsPage'
import { LogPage } from './ui/log/LogPage'
import { PeopleListPage } from './ui/people/PeopleListPage'
import { PersonPage } from './ui/people/PersonPage'
import { ContainerPage } from './ui/projects/ContainerPage'
import { ProjectsPage } from './ui/projects/ProjectsPage'
import { SettingsPage } from './ui/settings/SettingsPage'

function App() {
  const { user, ready } = useAuthUser()

  if (!ready) return null
  if (!user) return <SignInPage />

  return (
    <UIDProvider uid={user.uid}>
      <Routes>
        <Route element={<AppShell />}>
          <Route index element={<FeedPage />} />
          <Route path="/people" element={<PeopleListPage />} />
          <Route path="/people/:personID" element={<PersonPage />} />
          <Route path="/projects" element={<ProjectsPage />} />
          <Route path="/projects/:containerID" element={<ContainerPage />} />
          <Route path="/followups" element={<FollowUpsPage />} />
          <Route path="/log" element={<LogPage />} />
          {/* Capture lives inline on the feed now; the old page redirects. */}
          <Route path="/capture" element={<Navigate to="/?capture=1" replace />} />
          <Route path="/settings" element={<SettingsPage />} />
          <Route path="*" element={<NotFound />} />
        </Route>
      </Routes>
    </UIDProvider>
  )
}

export default App
